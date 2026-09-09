{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore) where

import Control.Monad (unless, forM_)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (withObject, (.:))
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Char8 as Bytes
import Data.List (stripPrefix, isPrefixOf, nub, sort)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Contract (CollectionContract(..), collectionContracts, rootSchema)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport (EvolutionReport(..), StepReport(..), FactChange(..), RecordedFact(..))
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Failure (OperationalFailure(..), StorageDiagnostic(..), StorageOperation(..))
import Kyyn.Domain.Git (Repository(..), TreePath(..), GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBasePath)
import Kyyn.Domain.Path (DirectoryScope, RelativePath, relativePath, relativeName, scopedPath, directoryScope)
import Kyyn.Domain.Root (Root(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(Draft, Ready, Accepted))
import qualified Kyyn.Domain.Workspace as Workspace
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Plumbing.Protocol.EvolutionRecord (encodeEvolutionRecord, decodeEvolutionRecord)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import qualified Kyyn.Plumbing.Capability.DhallHandling as DhallHandling
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore(..), workspaceLocation)
import qualified Kyyn.Porcelain.Capability.WorkspaceStore as WorkspaceStore
import qualified Kyyn.Porcelain.Capability.RootStore as RootStore
import Kyyn.Porcelain.Validated (validatedValue)

runEvolutionStore
  :: (FileSystem.FileSystem :> es, WorkspaceStore.WorkspaceStore :> es,
      RootStore.RootStore :> es, DhallHandling.DhallHandling :> es, Git.Git :> es, Failure :> es)
  => Eff (EvolutionStore : es) a -> Eff es a
runEvolutionStore = interpret $ \_ -> \case
  ReadEvolutionSummary (EvolutionWorkspace kb identity) revision ->
    runExceptT (summaryAt kb revision identity >>= requireWorkspace)
  ReadArchivedReport workspace@(EvolutionWorkspace (KnowledgeBase repository _) identity) revision -> runExceptT $ do
    path <- checked (workspaceLocation workspace >>= \p -> relativePath (relativeName p ++ "/result.json"))
    bytes <- ExceptT (Git.readFileAt repository revision path)
    traverse (\source -> do
      decoded <- either (throwE . pure . errorDiagnostic "evolution.invalid-report") pure (decodeEvolutionRecord source)
      (owner,_,_,report) <- either throwE pure decoded
      unless (owner == identity) (throwE [errorDiagnostic "evolution.invalid-report" "Archived report belongs to another evolution"])
      pure report) bytes
  FindAcceptance kb identity revision -> runExceptT (lookupAcceptance kb identity revision)
  ListEvolutions kb@(KnowledgeBase repo@(Repository scope) _) selection -> runExceptT $ do
    revision <- ExceptT (Git.resolveRevision repo "HEAD")
    path <- checked (relativePath "evolutions" >>= knowledgeBasePath kb)
    location <- checked (directoryScope (scopedPath scope path))
    local <- ExceptT (Right <$> FileSystem.listDirectory location)
    committed <- ExceptT (Git.readDirectoryAt repo revision (Subtree path))
    let names = sort (nub [relativeName p | paths <- [local,committed], p <- maybe [] id paths])
        identities = [identity | name <- names, Right identity <- [evolutionId name]]
    summaries <- traverse (summaryAt kb revision) identities
    pure [summary | Just summary@(EvolutionSummary _ _ state _) <- summaries, selection == AllEvolutions || state /= Draft]
  ResolveEvolution kb@(KnowledgeBase repo _) identity -> runExceptT $ do
    revision <- ExceptT (Git.resolveRevision repo "HEAD")
    summary <- summaryAt kb revision identity >>= requireWorkspace
    let EvolutionSummary workspace _ _ _ = summary
    pure workspace
  ReadEvolutionState (EvolutionWorkspace kb@(KnowledgeBase repo _) identity) -> runExceptT $ do
    revision <- ExceptT (Git.resolveRevision repo "HEAD")
    EvolutionSummary _ _ state _ <- summaryAt kb revision identity >>= requireWorkspace
    pure state
  MarkReady workspace -> runExceptT (setState workspace Ready)
  MarkDraft workspace -> runExceptT (setState workspace Draft)
  ExportAcceptedWorkspace (Candidate (EvolutionContext kb@(KnowledgeBase (Repository scope) _) identity (Before revision before)
      (WorkspaceSnapshot (WorkspaceManifest selected name explanation _ intermediates) source target change _)) report validated) -> runExceptT $ do
    let Root after _ code = validatedValue validated
    unless (revision == selected && target == code) (throwE [errorDiagnostic "evolution.archive-context"
      "Checked root or Before revision disagrees with captured workspace inputs"])
    notesPath <- checked (workspaceLocation (EvolutionWorkspace kb identity) >>= \p -> relativePath (relativeName p ++ "/notes"))
    notesScope <- checked (directoryScope (scopedPath scope notesPath))
    present <- ExceptT (Right <$> FileSystem.listDirectory notesScope)
    notes <- case present of
      Nothing -> checked (fileTree [])
      Just _ -> ExceptT (Right <$> FileSystem.readTree notesScope)
    encoded <- ExceptT (WorkspaceStore.encodeWorkspaceSnapshot
      (WorkspaceSnapshot (WorkspaceManifest revision name explanation Accepted intermediates) source target change notes))
    resultPath <- checked (relativePath "result.json")
    archive <- checked (fileTree ((resultPath,encodeEvolutionRecord identity before after report) : files encoded))
    destination <- checked (workspaceLocation (EvolutionWorkspace kb identity))
    pure (Subtree destination, archive)
  ReadWorkspace location -> runExceptT (readWorkspace location)
  MatchesCapturedInputs (EvolutionContext kb identity _ captured) -> runExceptT $ do
    current <- readWorkspace (EvolutionWorkspace kb identity)
    pure (Workspace.matchesCapturedInputs captured current)
  SaveCandidate (Candidate (EvolutionContext kb identity (Before revision before)
      snapshot@(WorkspaceSnapshot (WorkspaceManifest selected _ _ _ _) _ target _ _)) report root@(Root after facts code)) -> do
    parent <- candidateScope kb
    unless (revision == selected && code == target)
      (storageFailure WriteFile "candidate.json" "Candidate disagrees with its captured Before or target")
    _ <- RootStore.loadRootValueForChecking root >>= stored WriteFile "root"
    checkSavedReport WriteFile report
    capture <- WorkspaceStore.encodeWorkspaceSnapshot snapshot >>= stored WriteFile "capture"
    tree <- stored WriteFile "root" (fileTree (files facts ++ files code))
    allocated <- FileSystem.createUniqueDirectory parent
    location <- stored WriteFile "candidate" (directoryScope (scopedPath parent allocated))
    writeTree location "capture/" capture
    writeTree location "root/" tree
    metadata <- stored WriteFile "candidate.json" (relativePath "candidate.json")
    FileSystem.writeBytes location metadata (encodeEvolutionRecord identity before after report)
    pointer <- stored WriteFile "latest" (relativePath ("latest/" ++ evolutionIdName identity))
    FileSystem.replaceBytes parent pointer (Bytes.pack (relativeName allocated))
  LoadCandidate (EvolutionWorkspace kb identity) -> do
    parent <- candidateScope kb
    pointer <- stored ReadFile "latest" (relativePath ("latest/" ++ evolutionIdName identity))
    selected <- FileSystem.readOptionalBytes parent pointer
    case selected of
      Nothing -> pure (Right Nothing)
      Just bytes -> do
        key <- stored ReadFile "latest" (evolutionId (Bytes.unpack bytes))
        path <- stored ReadFile "latest" (relativePath (evolutionIdName key))
        location <- stored ReadFile "candidate" (directoryScope (scopedPath parent path))
        tree <- FileSystem.readTree location
        unless (all (\(p,_) -> let n = relativeName p in n == "candidate.json" ||
            "capture/" `isPrefixOf` n || "root/" `isPrefixOf` n) (files tree))
          (storageFailure ReadFile "candidate" "Unexpected saved-result file")
        metadata <- stored ReadFile "candidate.json" $ maybe (Left ("Missing candidate metadata" :: String)) Right
          (lookup "candidate.json" [(relativeName p,b) | (p,b) <- files tree])
        decoded <- stored ReadFile "candidate.json" (decodeEvolutionRecord metadata)
        capture <- stored ReadFile "capture" (subtree "capture/" tree)
        snapshot@(WorkspaceSnapshot (WorkspaceManifest revision _ _ _ _) _ target _ _) <-
          WorkspaceStore.readWorkspaceSnapshot capture >>= stored ReadFile "capture"
        rootFiles <- stored ReadFile "root" (subtree "root/" tree)
        facts <- stored ReadFile "root/facts" (fileTree [(p,b) | (p,b) <- files rootFiles, "facts/" `isPrefixOf` relativeName p])
        code <- stored ReadFile "root" (fileTree [(p,b) | (p,b) <- files rootFiles, not ("facts/" `isPrefixOf` relativeName p)])
        unless (code == target) (storageFailure ReadFile "root" "Saved root code differs from the captured target")
        case decoded of
          Left _ -> pure (Left [errorDiagnostic "candidate.stale" "Saved result no longer matches this kernel; apply the evolution again"])
          Right (owner,before,after,report) -> do
            unless (owner == identity) (storageFailure ReadFile "candidate.json" "Saved result belongs to another evolution")
            let root = Root after facts code
            _ <- RootStore.loadRootValueForChecking root >>= stored ReadFile "root"
            checkSavedReport ReadFile report
            pure (Right (Just (Candidate (EvolutionContext kb identity (Before revision before) snapshot) report root)))

lookupAcceptance :: (Git.Git :> es, WorkspaceStore.WorkspaceStore :> es)
  => KnowledgeBase -> EvolutionId -> GitRevision -> ExceptT [Diagnostic] (Eff es) (Maybe GitRevision)
lookupAcceptance kb identity revision = do
  current <- archiveBefore kb identity revision
  case current of
    Nothing -> pure Nothing
    Just before -> do
      introductions <- introducingCommits kb identity before [] [revision]
      case introductions of
        [accepted] -> pure (Just accepted)
        [] -> throwE [errorDiagnostic "evolution.acceptance-history" "Accepted archive has no introducing commit with its recorded Before as a parent"]
        _ -> throwE [errorDiagnostic "evolution.acceptance-history" "Accepted archive has multiple introducing commits; inspect the Git history"]

summaryAt :: (Git.Git :> es, WorkspaceStore.WorkspaceStore :> es, FileSystem.FileSystem :> es)
  => KnowledgeBase -> GitRevision -> EvolutionId -> ExceptT [Diagnostic] (Eff es) (Maybe EvolutionSummary)
summaryAt kb@(KnowledgeBase repository _) revision identity = do
  acceptance <- lookupAcceptance kb identity revision
  let workspace = EvolutionWorkspace kb identity
  case acceptance of
    Just accepted -> do
      path <- manifestPath workspace
      bytes <- ExceptT (Git.readFileAt repository revision path) >>= requireWorkspace
      WorkspaceManifest _ name _ _ _ <- decodeManifest bytes
      pure (Just (EvolutionSummary workspace (EvolutionName name) Accepted (Just accepted)))
    Nothing -> do
      manifest <- localManifest workspace
      case manifest of
        Nothing -> pure Nothing
        Just (WorkspaceManifest _ name _ state _) -> do
          unless (state /= Accepted) (throwE [errorDiagnostic "evolution.unverified-acceptance"
            "Local manifest says Accepted but Git does not; explicitly mark it Draft or Ready to correct it"])
          pure (Just (EvolutionSummary workspace (EvolutionName name) state Nothing))

setState :: (Git.Git :> es, WorkspaceStore.WorkspaceStore :> es, FileSystem.FileSystem :> es)
  => EvolutionWorkspace -> Workspace.EvolutionState -> ExceptT [Diagnostic] (Eff es) ()
setState workspace@(EvolutionWorkspace kb@(KnowledgeBase repository@(Repository scope) _) identity) state = do
  revision <- ExceptT (Git.resolveRevision repository "HEAD")
  accepted <- lookupAcceptance kb identity revision
  unless (accepted == Nothing) (throwE [errorDiagnostic "evolution.already-accepted" "This evolution is already accepted in Git"])
  WorkspaceManifest before name explanation _ intermediates <- localManifest workspace >>= requireWorkspace
  empty <- checked (fileTree [])
  encoded <- ExceptT (WorkspaceStore.encodeWorkspaceSnapshot
    (WorkspaceSnapshot (WorkspaceManifest before name explanation state intermediates) empty empty empty empty))
  path <- manifestPath workspace
  source <- checked $ maybe (Left "Missing encoded manifest") Right
    (lookup "manifest.dhall" [(relativeName p,b) | (p,b) <- files encoded])
  ExceptT (Right <$> FileSystem.replaceBytes scope path source)

manifestPath :: EvolutionWorkspace -> ExceptT [Diagnostic] (Eff es) RelativePath
manifestPath workspace = checked
  (workspaceLocation workspace >>= \p -> relativePath (relativeName p ++ "/manifest.dhall"))

localManifest :: (FileSystem.FileSystem :> es, WorkspaceStore.WorkspaceStore :> es)
  => EvolutionWorkspace -> ExceptT [Diagnostic] (Eff es) (Maybe WorkspaceManifest)
localManifest workspace@(EvolutionWorkspace (KnowledgeBase (Repository scope) _) _) = do
  path <- manifestPath workspace
  bytes <- ExceptT (Right <$> FileSystem.readOptionalBytes scope path)
  traverse decodeManifest bytes

decodeManifest :: WorkspaceStore.WorkspaceStore :> es
  => Bytes.ByteString -> ExceptT [Diagnostic] (Eff es) WorkspaceManifest
decodeManifest bytes = do
  path <- checked (relativePath "manifest.dhall")
  tree <- checked (fileTree [(path,bytes)])
  WorkspaceSnapshot manifest _ _ _ _ <- ExceptT (WorkspaceStore.readWorkspaceSnapshot tree)
  pure manifest

requireWorkspace :: Maybe a -> ExceptT [Diagnostic] (Eff es) a
requireWorkspace = maybe (throwE [errorDiagnostic "evolution.unknown" "No evolution workspace manifest was found"]) pure

archiveBefore :: (Git.Git :> es, WorkspaceStore.WorkspaceStore :> es)
  => KnowledgeBase -> EvolutionId -> GitRevision -> ExceptT [Diagnostic] (Eff es) (Maybe GitRevision)
archiveBefore kb@(KnowledgeBase repository _) identity revision = do
  path <- manifestPath (EvolutionWorkspace kb identity)
  bytes <- ExceptT (Git.readFileAt repository revision path)
  case bytes of
    Nothing -> pure Nothing
    Just source -> do
      WorkspaceManifest before _ _ state _ <- decodeManifest source
      pure (if state == Accepted then Just before else Nothing)

introducingCommits :: (Git.Git :> es, WorkspaceStore.WorkspaceStore :> es)
  => KnowledgeBase -> EvolutionId -> GitRevision -> [GitRevision] -> [GitRevision]
  -> ExceptT [Diagnostic] (Eff es) [GitRevision]
introducingCommits _ _ _ _ [] = pure []
introducingCommits kb@(KnowledgeBase repository _) identity before visited (revision:remaining)
  | revision `elem` visited = introducingCommits kb identity before visited remaining
  | otherwise = do
      parents <- ExceptT (Git.readCommitParents repository revision)
      introduced <- if before `elem` parents then do
        selected <- archiveBefore kb identity revision
        if selected /= Just before then pure False else do
          inherited <- traverse (archiveBefore kb identity) parents
          pure (Just before `notElem` inherited)
        else pure False
      rest <- introducingCommits kb identity before (revision:visited) (parents ++ remaining)
      pure (if introduced then revision:rest else rest)

checkSavedReport :: (DhallHandling.DhallHandling :> es, Failure :> es) => StorageOperation -> EvolutionReport -> Eff es ()
checkSavedReport operation (EvolutionReport steps) = forM_ steps $ \(StepReport _ changes) ->
  forM_ changes $ \(FactChange collection (FactId identity) before after) -> do
    unless (before /= Nothing || after /= Nothing)
      (storageFailure operation "candidate.json" "Fact change has neither a before nor an after value")
    forM_ [fact | Just fact <- [before,after]] $ \(RecordedFact schema value) -> do
      shape <- case [shape | CollectionContract name _ _ shape <- collectionContracts (rootSchema schema), name == collection] of
        [shape] -> pure (Record [("id", Scalar TextScalar), ("value", shape)])
        _ -> storageFailure operation "candidate.json" "Recorded fact names an unknown collection"
      _ <- DhallHandling.encodeValue shape value >>= stored operation "candidate.json"
      recordedId <- stored operation "candidate.json" (parseEither (withObject "Fact" (.: "id")) value)
      unless (recordedId == identity) (storageFailure operation "candidate.json" "Recorded fact ID disagrees with the change")

candidateScope :: Failure :> es => KnowledgeBase -> Eff es DirectoryScope
candidateScope kb@(KnowledgeBase (Repository scope) _) = stored ReadDirectoryTree ".kyyn/candidates" $ do
  path <- relativePath ".kyyn/candidates" >>= knowledgeBasePath kb
  directoryScope (scopedPath scope path)

writeTree :: (FileSystem.FileSystem :> es, Failure :> es) => DirectoryScope -> String -> FileTree -> Eff es ()
writeTree scope prefix tree = forM_ (files tree) $ \(path,bytes) -> do
  destination <- stored WriteFile prefix (relativePath (prefix ++ relativeName path))
  FileSystem.writeBytes scope destination bytes

subtree :: String -> FileTree -> Either String FileTree
subtree prefix tree = traverse (\(p,b) -> (,b) <$> relativePath p)
  [(p,b) | (path,b) <- files tree, Just p <- [stripPrefix prefix (relativeName path)]] >>= fileTree

stored :: (Show e, Failure :> es) => StorageOperation -> FilePath -> Either e a -> Eff es a
stored operation path = either (storageFailure operation path . show) pure

storageFailure :: Failure :> es => StorageOperation -> FilePath -> String -> Eff es a
storageFailure operation path = raiseFailure . StorageUnavailable . StorageDiagnostic operation path

readWorkspace
  :: (FileSystem.FileSystem :> es, WorkspaceStore.WorkspaceStore :> es)
  => EvolutionWorkspace -> ExceptT [Diagnostic] (Eff es) WorkspaceSnapshot
readWorkspace (EvolutionWorkspace kb@(KnowledgeBase (Repository scope) _) identity) = do
  path <- checked (workspaceLocation (EvolutionWorkspace kb identity))
  location <- checked (directoryScope (scopedPath scope path))
  tree <- ExceptT (Right <$> FileSystem.readTree location)
  ExceptT (WorkspaceStore.readWorkspaceSnapshot tree)

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "evolution.capture") pure
