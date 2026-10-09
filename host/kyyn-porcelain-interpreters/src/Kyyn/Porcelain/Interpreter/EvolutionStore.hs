{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore) where

import Control.Monad (unless, forM_)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (withObject, (.:))
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Char8 as Bytes
import Data.List (stripPrefix, sort)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Contract (CollectionContract(..), collectionContracts, rootSchema)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport (EvolutionReport(..), StepReport(..), Change(..), RecordedFact(..))
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Failure (OperationalFailure(..), StorageDiagnostic(..), StorageOperation(..))
import Kyyn.Domain.Git (Repository(..), TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBasePath, cacheLocation)
import Kyyn.Domain.Path (DirectoryScope, RelativePath, relativePath, relativeName, scopedPath, directoryScope)
import Kyyn.Domain.Root (Root(..), factsLocation, isFactPath, isRootMaterial)
import Kyyn.Porcelain.Protocol.RecipePersistence (encodeRecipeContracts, decodeRecipeContracts)
import Kyyn.Domain.Recipe (recipeId)
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(Draft, Ready, Accepted))
import qualified Kyyn.Domain.Workspace as Workspace
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import Kyyn.Plumbing.Protocol.EvolutionRecord (encodeEvolutionRecord, decodeEvolutionRecord)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import qualified Kyyn.Plumbing.Capability.DhallHandling as DhallHandling
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore(..), workspaceLocation)
import qualified Kyyn.Porcelain.Capability.WorkspaceStore as WorkspaceStore
import qualified Kyyn.Porcelain.Capability.RootStore as RootStore
import Kyyn.Porcelain.Validated (validatedValue)

runEvolutionStore
  :: (FileSystem.FileSystem :> es, WorkspaceStore.WorkspaceStore :> es,
      RootStore.RootStore :> es, DhallHandling.DhallHandling :> es, Failure :> es)
  => Eff (EvolutionStore : es) a -> Eff es a
runEvolutionStore = interpret $ \_ -> \case
  ReadEvolutionSummary (EvolutionWorkspace kb identity) ->
    runExceptT (workspaceSummary kb identity >>= requireWorkspace)
  ReadArchivedReport workspace@(EvolutionWorkspace (KnowledgeBase (Repository scope) _) identity) -> runExceptT $ do
    path <- checked (workspaceLocation workspace >>= \p -> relativePath (relativeName p ++ "/result.dhall"))
    bytes <- ExceptT (Right <$> FileSystem.readOptionalBytes scope path)
    traverse (\source -> do
      decoded <- ExceptT (decodeEvolutionRecord source >>= pure . either
        (Left . pure . errorDiagnostic "evolution.invalid-report") Right)
      (owner,_,_,report) <- either throwE pure decoded
      unless (owner == identity) (throwE [errorDiagnostic "evolution.invalid-report" "Archived report belongs to another evolution"])
      pure report) bytes
  ListEvolutions kb@(KnowledgeBase (Repository scope) _) selection -> runExceptT $ do
    path <- checked (relativePath "evolutions" >>= knowledgeBasePath kb)
    location <- checked (directoryScope (scopedPath scope path))
    local <- ExceptT (Right <$> FileSystem.listDirectory location)
    let names = sort [relativeName p | p <- maybe [] id local]
        identities = [identity | name <- names, Right identity <- [evolutionId name]]
    summaries <- traverse (\identity -> workspaceSummary kb identity >>= requireWorkspace) identities
    pure [summary | summary@(EvolutionSummary _ _ state) <- summaries, selection == AllEvolutions || state /= Draft]
  ResolveEvolution kb identity -> runExceptT $ do
    EvolutionSummary workspace _ _ <- workspaceSummary kb identity >>= requireWorkspace
    pure workspace
  ReadEvolutionState (EvolutionWorkspace kb identity) -> runExceptT $ do
    EvolutionSummary _ _ state <- workspaceSummary kb identity >>= requireWorkspace
    pure state
  MarkReady workspace -> runExceptT (setState workspace Ready)
  MarkDraft workspace -> runExceptT (setState workspace Draft)
  ExportAcceptedWorkspace (Candidate (EvolutionContext kb@(KnowledgeBase (Repository scope) _) identity (Before revision before)
      (WorkspaceSnapshot (WorkspaceManifest selected name explanation _ kind) source target change _)) report validated) -> runExceptT $ do
    let Root after _ code _ = validatedValue validated
    unless (revision == selected && target == code) (throwE [errorDiagnostic "evolution.archive-context"
      "Checked root or Before revision disagrees with captured workspace inputs"])
    notesPath <- checked (workspaceLocation (EvolutionWorkspace kb identity) >>= \p -> relativePath (relativeName p ++ "/notes"))
    notesScope <- checked (directoryScope (scopedPath scope notesPath))
    present <- ExceptT (Right <$> FileSystem.listDirectory notesScope)
    notes <- case present of
      Nothing -> checked (fileTree [])
      Just _ -> ExceptT (Right <$> FileSystem.readTree notesScope)
    encoded <- ExceptT (WorkspaceStore.encodeWorkspaceSnapshot
      (WorkspaceSnapshot (WorkspaceManifest revision name explanation Accepted kind) source target change notes))
    resultPath <- checked (relativePath "result.dhall")
    document <- ExceptT (encodeEvolutionRecord identity before after report)
    archive <- checked (fileTree ((resultPath,document) : files encoded))
    destination <- checked (workspaceLocation (EvolutionWorkspace kb identity))
    pure (Subtree destination, archive)
  ReadWorkspace location -> runExceptT (readWorkspace location)
  MatchesCapturedInputs (EvolutionContext kb identity _ captured) -> runExceptT $ do
    current <- readWorkspace (EvolutionWorkspace kb identity)
    pure (Workspace.matchesCapturedInputs captured current)
  SaveCandidate (Candidate (EvolutionContext kb identity (Before revision before)
      snapshot@(WorkspaceSnapshot (WorkspaceManifest selected _ _ _ _) _ target _ _)) report root@(Root after facts code recipes)) -> do
    parent <- candidateScope kb
    unless (revision == selected && code == target)
      (storageFailure WriteFile "candidate.dhall" "Candidate disagrees with its captured Before or target")
    _ <- RootStore.loadRootValueForChecking root >>= stored WriteFile "root"
    checkSavedReport WriteFile report
    capture <- WorkspaceStore.encodeWorkspaceSnapshot snapshot >>= stored WriteFile "capture"
    recipeFiles <- RootStore.encodeRootRecipes recipes >>= stored WriteFile "recipes.dhall"
    tree <- stored WriteFile "root" (fileTree (files recipeFiles ++ files facts ++ files code))
    let KnowledgeBase (Repository repositoryScope) _ = kb
    cache <- stored WriteFile (relativeName cacheLocation) (knowledgeBasePath kb cacheLocation)
    FileSystem.ensureIgnoredDirectory repositoryScope cache
    allocated <- FileSystem.createUniqueDirectory parent
    location <- stored WriteFile "candidate" (directoryScope (scopedPath parent allocated))
    writeTree location "capture/" capture
    writeTree location "root/" tree
    metadata <- stored WriteFile "candidate.dhall" (relativePath "candidate.dhall")
    document <- encodeEvolutionRecord identity before after report >>= stored WriteFile "candidate.dhall"
    FileSystem.writeBytes location metadata document
    stateContracts <- encodeRecipeContracts recipes >>= stored WriteFile "recipe-contracts.dhall"
    contractsPath <- stored WriteFile "recipe-contracts.dhall" (relativePath "recipe-contracts.dhall")
    FileSystem.writeBytes location contractsPath stateContracts
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
        case lookup "candidate.dhall" [(relativeName p,b) | (p,b) <- files tree] of
          Just metadata -> do
            decoded <- decodeEvolutionRecord metadata >>= stored ReadFile "candidate.dhall"
            capture <- stored ReadFile "capture" (subtree "capture/" tree)
            captured <- WorkspaceStore.readWorkspaceSnapshot capture
            case (decoded,captured) of
              (Right (owner,before,after,report), Right snapshot@(WorkspaceSnapshot (WorkspaceManifest revision _ _ _ _) _ target _ _)) -> do
                rootFiles <- stored ReadFile "root" (subtree "root/" tree)
                facts <- stored ReadFile ("root/" ++ relativeName factsLocation) (fileTree [(p,b) | (p,b) <- files rootFiles, isFactPath p])
                code <- stored ReadFile "root" (fileTree [(p,b) | (p,b) <- files rootFiles, not (isRootMaterial p)])
                definitions <- RootStore.readRootRecipes rootFiles >>= stored ReadFile "root/recipes.dhall"
                contractBytes <- maybe (storageFailure ReadFile "recipe-contracts.dhall" "Missing candidate recipe contracts") pure
                  (lookup "recipe-contracts.dhall" [(relativeName p,b) | (p,b) <- files tree])
                contracts <- decodeRecipeContracts contractBytes >>= stored ReadFile "recipe-contracts.dhall"
                unless (sort [name | Fact (FactId name) _ <- definitions] == sort [name | (FactId name,_,_) <- contracts])
                  (storageFailure ReadFile "recipe-contracts.dhall" "Candidate recipe membership differs from its contracts")
                resolved <- traverse (\definition@(Fact ident _) -> case [(name,contract) | (actual,name,contract) <- contracts, actual == ident] of
                  [(name,contract)] -> pure (definition,name,contract)
                  _ -> storageFailure ReadFile "recipe-contracts.dhall" "Missing or ambiguous recipe contract") definitions
                recipes <- RootStore.readRecipeStates resolved rootFiles >>= stored ReadFile "root/recipes"
                unless (code == target) (storageFailure ReadFile "root" "Saved root code differs from the captured target")
                unless (owner == identity) (storageFailure ReadFile "candidate.dhall" "Saved result belongs to another evolution")
                let root = Root after facts code recipes
                _ <- RootStore.loadRootValueForChecking root >>= stored ReadFile "root"
                checkSavedReport ReadFile report
                pure (Right (Just (Candidate (EvolutionContext kb identity (Before revision before) snapshot) report root)))
              (Left diagnostics, _) -> pure (Left diagnostics)
              (_, Left diagnostics) -> pure (Left diagnostics)
          Nothing -> storageFailure ReadFile "candidate.dhall" "Missing candidate record"

workspaceSummary :: (WorkspaceStore.WorkspaceStore :> es, FileSystem.FileSystem :> es)
  => KnowledgeBase -> EvolutionId -> ExceptT [Diagnostic] (Eff es) (Maybe EvolutionSummary)
workspaceSummary kb identity = do
  let workspace = EvolutionWorkspace kb identity
  manifest <- localManifest workspace
  pure (fmap (\(WorkspaceManifest _ name _ state _) -> EvolutionSummary workspace (EvolutionName name) state) manifest)

setState :: (WorkspaceStore.WorkspaceStore :> es, FileSystem.FileSystem :> es)
  => EvolutionWorkspace -> Workspace.EvolutionState -> ExceptT [Diagnostic] (Eff es) ()
setState workspace@(EvolutionWorkspace (KnowledgeBase (Repository scope) _) _) state = do
  WorkspaceManifest before name explanation current kind <- localManifest workspace >>= requireWorkspace
  unless (current /= Accepted) (throwE [errorDiagnostic "evolution.already-accepted" "This evolution is already Accepted"])
  empty <- checked (fileTree [])
  encoded <- ExceptT (WorkspaceStore.encodeWorkspaceSnapshot
    (WorkspaceSnapshot (WorkspaceManifest before name explanation state kind) empty empty empty empty))
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

checkSavedReport :: (DhallHandling.DhallHandling :> es, Failure :> es) => StorageOperation -> EvolutionReport -> Eff es ()
checkSavedReport operation (EvolutionReport _ steps) = forM_ steps $ \(StepReport _ changes) ->
  forM_ changes check
  where
    check (RecipeChange (FactId identity) before after) = do
      _ <- stored operation "candidate.dhall" (recipeId (Text.unpack identity))
      unless (before /= Nothing || after /= Nothing)
        (storageFailure operation "candidate.dhall" "Recipe change has neither a before nor an after value")
    check (FactChange collection (FactId identity) before after) = do
      unless (before /= Nothing || after /= Nothing)
        (storageFailure operation "candidate.dhall" "Fact change has neither a before nor an after value")
      forM_ [fact | Just fact <- [before,after]] $ \(RecordedFact schema value) -> do
        shape <- case [shape | CollectionContract name _ _ shape <- collectionContracts (rootSchema schema), name == collection] of
          [shape] -> pure (Record [("id", Scalar TextScalar), ("value", shape)])
          _ -> storageFailure operation "candidate.dhall" "Recorded fact names an unknown collection"
        _ <- DhallHandling.encodeValue shape value >>= stored operation "candidate.dhall"
        recordedId <- stored operation "candidate.dhall" (parseEither (withObject "Fact" (.: "id")) value)
        unless (recordedId == identity) (storageFailure operation "candidate.dhall" "Recorded fact ID disagrees with the change")

candidateScope :: Failure :> es => KnowledgeBase -> Eff es DirectoryScope
candidateScope kb@(KnowledgeBase (Repository scope) _) = stored ReadDirectoryTree ".kyyn/candidates" $ do
  path <- relativePath (relativeName cacheLocation ++ "/candidates") >>= knowledgeBasePath kb
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
