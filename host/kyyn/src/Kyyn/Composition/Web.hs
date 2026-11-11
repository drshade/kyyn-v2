{-# LANGUAGE DataKinds #-}
module Kyyn.Composition.Web (serveWeb) where

import Control.Monad (when)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value(Null), object, (.=))
import Data.List (stripPrefix)
import Kyyn.Configuration
import Kyyn.Composition.Runtime
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.Git (Repository(..), TreePath(..), revisionName)
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (DirectoryScope, relativePath, relativeName)
import Kyyn.Domain.Query (QueryDescriptor(..), QueryResult(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(..))
import qualified Kyyn.Plumbing.Capability.Git as Git
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import qualified Kyyn.Porcelain.Capability.WorkspaceStore as WorkspaceStore
import Kyyn.Plumbing.Capability.DhallHandling (encodeValue)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Store
import qualified Kyyn.Porcelain.Capability.RootStore as RootStore
import qualified Kyyn.Porcelain.Capability.Root as Root
import Kyyn.Porcelain.Capability.RootExecution (prepareRoot, selectQuery, queryRoot)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Surfaces.Result
import Kyyn.Web (runServer, ViewSource(..))

serveWeb :: Host -> DirectoryScope -> Int -> Maybe EvolutionId -> IO Response
serveWeb host scope port draft
  | port < 0 || port > 65535 = pure (refusal [errorDiagnostic "web.port" "Port must be between 0 and 65535"])
  | otherwise = do
      selected <- selectKnowledgeBase host scope
      case selected of
        Left failure -> pure failure
        Right _ -> runServer port pages invoke
  where
    pages = do
      selected <- selectKnowledgeBase host scope
      case selected of
        Left failure -> pure (Left failure)
        Right (SelectedKb kb@(KnowledgeBase repository _) revision _) -> do
          result <- runBase host . runWorkspaceStore . runEvolutionStore $ runExceptT $ do
            (base,tree) <- case draft of
              Nothing -> do
                path <- checked (RootStore.rootLocation kb)
                manifestPath <- child path "kb.dhall"
                manifest <- ExceptT (Git.readFileAt repository revision manifestPath)
                viewPath <- child path "views"
                present <- ExceptT (Git.readDirectoryAt repository revision (Subtree viewPath))
                views <- case present of
                  Nothing -> checked (fileTree [])
                  Just _ -> ExceptT (Git.readTreeAt repository revision (Subtree viewPath))
                tree <- pageTree manifest views
                pure (revision,tree)
              Just identity -> do
                let workspace = EvolutionWorkspace kb identity
                path <- checked (Store.workspaceLocation workspace)
                let Repository scope' = repository
                manifestPath <- child path "manifest.dhall"
                pageManifest <- child path "target/kb.dhall"
                viewPath <- child path "target/views"
                captured <- ExceptT (Right <$> FileSystem.readSelectedTree scope' [manifestPath,pageManifest,viewPath])
                local <- rebase (relativeName path ++ "/") captured
                WorkspaceSnapshot (WorkspaceManifest base _ _ state _) tree _ _ <-
                  ExceptT (WorkspaceStore.readWorkspaceSnapshot local)
                when (state == Accepted) (throwE [errorDiagnostic "web.accepted" "Restart without --evolution to browse the accepted root"])
                pure (base,tree)
            views <- ExceptT (RootStore.readViews tree)
            pure (ViewSource (context base) views tree)
          pure (either (Left . operationalFailure) (either (Left . refusal) Right) result)
    checked value = either (throwE . pure . errorDiagnostic "web.source") pure value
    child path suffix = checked (relativePath (relativeName path ++ "/" ++ suffix))
    rebase prefix tree = do
      entries <- traverse (\(path,bytes) -> (,bytes) <$> checked (relativePath path))
        [(path,bytes) | (key,bytes) <- files tree, Just path <- [stripPrefix prefix (relativeName key)]]
      checked (fileTree entries)
    pageTree manifest views = do
      entries <- traverse (\(path,bytes) -> (,bytes) <$> checked (relativePath ("views/" ++ relativeName path))) (files views)
      key <- checked (relativePath "kb.dhall")
      checked (fileTree (maybe entries (\bytes -> (key,bytes):entries) manifest))
    context revision = object ["revision" .= revisionName revision, "evolution" .= fmap evolutionIdName draft]
    invoke name args = do
      selected <- selectKnowledgeBase host scope
      case selected of
        Left failure -> pure (Null,failure)
        Right (SelectedKb kb revision _) -> do
          result <- withRuntimeResult host $ \settings -> runRuntime host settings . runPluginPreparation . runToolPreparation
            . runRootOpening . runWorkspaceStore . runEvolutionStore . runRootExecution $ runExceptT $ do
              (base,prepared) <- case draft of
                Nothing -> (revision,) <$> ExceptT (Root.prepareRootAt kb revision)
                Just identity -> do
                  let workspace = EvolutionWorkspace kb identity
                  state <- ExceptT (Store.readEvolutionState workspace)
                  when (state == Accepted) (throwE [errorDiagnostic "web.accepted" "Restart without --evolution to browse the accepted root"])
                  saved <- ExceptT (Store.loadCheckedCandidate workspace)
                  case saved of
                    Nothing -> throwE [errorDiagnostic "evolution.no-candidate"
                      ("Run kyyn-v2 evolution check " ++ evolutionIdName identity ++ "; no successfully checked candidate is available")]
                    Just (Candidate (EvolutionContext _ _ before _) _ root) ->
                      (beforeRevision before,) <$> ExceptT (prepareRoot root)
              descriptor@(QueryDescriptor _ _ input _) <- ExceptT (pure (selectQuery prepared name))
              _ <- ExceptT (encodeValue (contractShape input) args)
              QueryResult (CheckedValue _ value) _ <- ExceptT (queryRoot prepared descriptor (CheckedValue (contractId input) args))
              pure (context base,success value [])
          pure $ case result of
            Left failure -> (context revision,failure)
            Right (Left failure) -> (context revision,operationalFailure failure)
            Right (Right (Left diagnostics)) -> (context revision,refusal diagnostics)
            Right (Right (Right value)) -> value
