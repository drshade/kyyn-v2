module Kyyn.Porcelain.Capability.Root
  ( checkRootAt, inspectRootAt, sourceCodeAt, sourceRootAt, listRootTools, selectRootTool
  , selectSchemaType, selectCollection ) where

import Effectful (Eff, (:>))
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Coerce (coerce)
import Kyyn.Domain.Contract (RootContract, CollectionContract(..), rootSchema, rootType, collectionContracts)
import Kyyn.Domain.DataType (DataType(..), reachableTypes, haskellType)
import Kyyn.Domain.Plugin (MethodName(..))
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Porcelain.Capability.Tool (ToolPreparation, PreparedTool(..), prepareTools)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePlugins)
import Kyyn.Domain.Evolution (EvolutionId, EvolutionWorkspace(..))
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..))
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Git (GitRevision, TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Root (Root, CheckedValue, SourceRoot(..))
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootAt, loadSourceAt, openCapturedSource)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Evolution
import Kyyn.Porcelain.Capability.RootExecution (RootExecution)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation, loadRootValueForChecking)
import Kyyn.Porcelain.Capability.Validation (checkRoot)
import Kyyn.Porcelain.Validated (Validated, validatedValue)

sourceRootAt :: (RootOpening :> es, Evolution.EvolutionStore :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> Eff es (Either [Diagnostic] SourceRoot)
sourceRootAt kb@(KnowledgeBase repository _) revision workspace = runExceptT $ case workspace of
  Nothing -> do
    location <- ExceptT (pure (either (Left . pure . errorDiagnostic "kb.path") Right (rootLocation kb)))
    ExceptT (loadSourceAt repository revision (Subtree location))
  Just identity -> do
    WorkspaceSnapshot _ _ code _ _ <- ExceptT (Evolution.readWorkspace (EvolutionWorkspace kb identity))
    ExceptT (openCapturedSource code)

selectSchemaType :: RootContract -> String -> Either [Diagnostic] DataType
selectSchemaType contract name = case
  [t | t@(Algebraic _ _ _) <- reachableTypes (rootType (rootSchema contract)), haskellType t == name] of
    [t] -> Right t
    _ -> Left [errorDiagnostic "schema.type-unknown" ("Unknown schema type: " ++ name ++ ". Use root schema list for resolved names.")]

selectCollection :: RootContract -> String -> Either [Diagnostic] CollectionContract
selectCollection contract name = case
  [c | c@(CollectionContract actual _ _ _) <- collectionContracts (rootSchema contract), actual == name] of
    [c] -> Right c
    _ -> Left [errorDiagnostic "fact.collection-unknown" ("Unknown collection: " ++ name)]

sourceCodeAt :: (RootOpening :> es, Evolution.EvolutionStore :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> Eff es (Either [Diagnostic] FileTree)
sourceCodeAt kb@(KnowledgeBase repository _) revision workspace = runExceptT $ case workspace of
  Nothing -> do
    location <- ExceptT (pure (either (Left . pure . errorDiagnostic "kb.path") Right (rootLocation kb)))
    SourceRoot _ code _ _ <- ExceptT (loadSourceAt repository revision (Subtree location))
    pure code
  Just identity -> do
    WorkspaceSnapshot _ _ code _ _ <- ExceptT (Evolution.readWorkspace (EvolutionWorkspace kb identity))
    pure code

listRootTools :: (ToolPreparation :> es, PluginPreparation :> es, RootOpening :> es, Evolution.EvolutionStore :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> Eff es (Either [Diagnostic] [PreparedTool])
listRootTools kb revision workspace = runExceptT $ do
  code <- ExceptT (sourceCodeAt kb revision workspace)
  plugins <- ExceptT (preparePlugins code)
  ExceptT (prepareTools code plugins)

selectRootTool :: (ToolPreparation :> es, PluginPreparation :> es, RootOpening :> es, Evolution.EvolutionStore :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> MethodName -> Eff es (Either [Diagnostic] PreparedTool)
selectRootTool kb revision workspace name = runExceptT $ do
  tools <- ExceptT (listRootTools kb revision workspace)
  case [tool | tool@(PreparedTool (ToolDescriptor actual _ _ _) _ _ _) <- tools, actual == name] of
    [tool] -> pure tool
    _ -> throwE [errorDiagnostic "tool.unknown" ("No registered tool named " ++ coerce name)]

checkRootAt :: (RootOpening :> es, RootExecution :> es, RootStore :> es)
  => KnowledgeBase -> GitRevision -> Eff es (CheckResult (Validated Root))
checkRootAt kb@(KnowledgeBase repository _) revision = case rootLocation kb of
  Left message -> pure (Rejected (ValidationReport [errorDiagnostic "kb.path" message]))
  Right path -> do
    loaded <- loadRootAt repository revision (Subtree path)
    either (pure . Rejected . ValidationReport) checkRoot loaded

inspectRootAt :: (RootOpening :> es, RootExecution :> es, RootStore :> es)
  => KnowledgeBase -> GitRevision -> Eff es (CheckResult (Validated Root, CheckedValue))
inspectRootAt kb revision = do
  checked <- checkRootAt kb revision
  case checked of
    Rejected report -> pure (Rejected report)
    Passed root (ValidationReport warnings) -> do
      value <- loadRootValueForChecking (validatedValue root)
      pure $ case value of
        Left diagnostics -> Rejected (ValidationReport (warnings ++ diagnostics))
        Right facts -> Passed (root,facts) (ValidationReport warnings)
