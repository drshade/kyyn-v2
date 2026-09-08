{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore) where

import Control.Monad (unless, forM_)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (withObject, (.:))
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Char8 as Bytes
import Data.List (stripPrefix, isPrefixOf)
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
import Kyyn.Domain.Path (DirectoryScope, relativePath, relativeName, scopedPath, directoryScope)
import Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(Draft, Accepted))
import qualified Kyyn.Domain.Workspace as Workspace
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Plumbing.Protocol.Evolution (identityEvolutionSource)
import Kyyn.Plumbing.Protocol.Candidate (encodeCandidateMetadata, decodeCandidateMetadata)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import qualified Kyyn.Plumbing.Capability.DhallHandling as DhallHandling
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore(..))
import qualified Kyyn.Porcelain.Capability.RootOpening as RootOpening
import qualified Kyyn.Porcelain.Capability.WorkspaceStore as WorkspaceStore
import qualified Kyyn.Porcelain.Capability.RootStore as RootStore

runEvolutionStore
  :: (FileSystem.FileSystem :> es, WorkspaceStore.WorkspaceStore :> es, RootOpening.RootOpening :> es,
      RootStore.RootStore :> es, DhallHandling.DhallHandling :> es, Git.Git :> es, Failure :> es)
  => Eff (EvolutionStore : es) a -> Eff es a
runEvolutionStore = interpret $ \_ -> \case
  FindAcceptance kb identity revision -> runExceptT $ do
    current <- archiveBefore kb identity revision
    case current of
      Nothing -> pure Nothing
      Just before -> do
        introductions <- introducingCommits kb identity before [] [revision]
        case introductions of
          [accepted] -> pure (Just accepted)
          [] -> throwE [errorDiagnostic "evolution.acceptance-history" "Accepted archive has no introducing commit with its recorded Before as a parent"]
          _ -> throwE [errorDiagnostic "evolution.acceptance-history" "Accepted archive has multiple introducing commits; inspect the Git history"]
  CreateEvolution kb@(KnowledgeBase repository@(Repository scope) _) (EvolutionName name) revision -> runExceptT $ do
    rootPath <- checked (relativePath "root" >>= knowledgeBasePath kb)
    SourceRoot _ code (RootDefinition _ _ _ _ sources) <-
      ExceptT (RootOpening.loadSourceAt repository revision (Subtree rootPath))
    empty <- checked (fileTree [])
    entryPath <- checked (relativePath "Evolution.hs")
    change <- checked (fileTree [(entryPath,identityEvolutionSource)])
    tree <- ExceptT (WorkspaceStore.encodeWorkspaceSnapshot
      (WorkspaceSnapshot (WorkspaceManifest revision name "" Draft []) sources code change empty))
    parentPath <- checked (relativePath "evolutions" >>= knowledgeBasePath kb)
    parent <- checked (directoryScope (scopedPath scope parentPath))
    allocated <- ExceptT (Right <$> FileSystem.createUniqueDirectory parent)
    identity <- checked (evolutionId (relativeName allocated))
    location <- checked (directoryScope (scopedPath parent allocated))
    forM_ (files tree) $ \(path,bytes) -> ExceptT (Right <$> FileSystem.writeBytes location path bytes)
    pure (EvolutionWorkspace kb identity)
  CaptureEvolution location@(EvolutionWorkspace kb@(KnowledgeBase repository _) identity) -> runExceptT $ do
    snapshot@(WorkspaceSnapshot (WorkspaceManifest revision _ _ _ _) beforeCopy _ _ _) <- readWorkspace location
    rootPath <- checked (relativePath "root" >>= knowledgeBasePath kb)
    SourceRoot contract _ (RootDefinition _ _ _ _ sources) <-
      ExceptT (RootOpening.loadSourceAt repository revision (Subtree rootPath))
    unless (beforeCopy == sources) (throwE [errorDiagnostic "evolution.before-mismatch"
      "before/ must match the selected revision's src/ tree; refresh it from that revision"])
    pure (CapturedEvolution (EvolutionContext kb identity (Before revision contract) snapshot))
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
    FileSystem.writeBytes location metadata (encodeCandidateMetadata identity before after report)
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
        decoded <- stored ReadFile "candidate.json" (decodeCandidateMetadata metadata)
        capture <- stored ReadFile "capture" (subtree "capture/" tree)
        snapshot@(WorkspaceSnapshot (WorkspaceManifest revision _ _ _ _) _ target _ _) <-
          WorkspaceStore.readWorkspaceSnapshot capture >>= stored ReadFile "capture"
        rootFiles <- stored ReadFile "root" (subtree "root/" tree)
        facts <- stored ReadFile "root/facts" (fileTree [(p,b) | (p,b) <- files rootFiles, "facts/" `isPrefixOf` relativeName p])
        code <- stored ReadFile "root" (fileTree [(p,b) | (p,b) <- files rootFiles, not ("facts/" `isPrefixOf` relativeName p)])
        unless (code == target) (storageFailure ReadFile "root" "Saved root code differs from the captured target")
        case decoded of
          Left diagnostics -> pure (Left diagnostics)
          Right (owner,before,after,report) -> do
            unless (owner == identity) (storageFailure ReadFile "candidate.json" "Saved result belongs to another evolution")
            let root = Root after facts code
            _ <- RootStore.loadRootValueForChecking root >>= stored ReadFile "root"
            checkSavedReport ReadFile report
            pure (Right (Just (Candidate (EvolutionContext kb identity (Before revision before) snapshot) report root)))

archiveBefore :: (Git.Git :> es, WorkspaceStore.WorkspaceStore :> es)
  => KnowledgeBase -> EvolutionId -> GitRevision -> ExceptT [Diagnostic] (Eff es) (Maybe GitRevision)
archiveBefore kb@(KnowledgeBase repository _) identity revision = do
  path <- checked (relativePath ("evolutions/" ++ evolutionIdName identity ++ "/manifest.dhall") >>= knowledgeBasePath kb)
  bytes <- ExceptT (Git.readFileAt repository revision path)
  case bytes of
    Nothing -> pure Nothing
    Just source -> do
      manifestPath <- checked (relativePath "manifest.dhall")
      tree <- checked (fileTree [(manifestPath,source)])
      WorkspaceSnapshot (WorkspaceManifest before _ _ state _) _ _ _ _ <- ExceptT (WorkspaceStore.readWorkspaceSnapshot tree)
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
  path <- checked (relativePath ("evolutions/" ++ evolutionIdName identity) >>= knowledgeBasePath kb)
  location <- checked (directoryScope (scopedPath scope path))
  tree <- ExceptT (Right <$> FileSystem.readTree location)
  ExceptT (WorkspaceStore.readWorkspaceSnapshot tree)

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "evolution.capture") pure
