{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module Kyyn.Porcelain.Interpreter.Inspection (runInspection) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (nub, sort, isSuffixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Query (QueryDefinition(..), QueryDescriptor(..), QueryResult(..))
import Kyyn.Domain.Tool (ToolDefinition(..), ToolDescriptor(..))
import Kyyn.Domain.Plugin (MethodName(..))
import Kyyn.Domain.Path (relativeName)
import Kyyn.Domain.DataType (definingModule)
import Kyyn.Domain.Recipe (StoredRecipe(..), RecipeDefinition(..), recipeDefinition, DescriptionFormat(Tree))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Git (TreePath(..))
import Kyyn.Domain.Inspection
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Root (Root(..), RootDefinition(..), SourceRoot(..), isRootMaterial)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(..))
import qualified Kyyn.Plumbing.Capability.Git as Git
import qualified Kyyn.Plumbing.Capability.DhallHandling as Dhall
import qualified Kyyn.Porcelain.Capability.RootExecution as Query
import qualified Kyyn.Porcelain.Capability.Tool as Tool
import qualified Kyyn.Porcelain.Capability.RecipeInspection as Recipe
import Kyyn.Porcelain.Capability.Inspection
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Store
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootAt)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation, loadRootValueForChecking, readRootDefinition)

runInspection :: (RootOpening :> es, RootStore :> es, Store.EvolutionStore :> es, Git.Git :> es,
  Query.RootExecution :> es, Tool.ToolPreparation :> es, Recipe.RecipeInspection :> es, Dhall.DhallHandling :> es)
  => Eff (Inspection : es) a -> Eff es a
runInspection = interpret $ \_ -> \case
  InspectSnapshot kb@(KnowledgeBase repository _) revision selected -> runExceptT $ do
    (base,root@(Root _ _ code _)) <- case selected of
      Nothing -> do
        path <- checked (rootLocation kb)
        (revision,) <$> ExceptT (loadRootAt repository revision (Subtree path))
      Just identity -> do
        let workspace = EvolutionWorkspace kb identity
        state <- ExceptT (Store.readEvolutionState workspace)
        case state of
          Accepted -> throwE [errorDiagnostic "inspection.accepted" "This evolution is accepted; use the accepted KB link"]
          _ -> pure ()
        candidate <- ExceptT (Store.loadCheckedCandidate workspace)
        case candidate of
          Nothing -> throwE [errorDiagnostic "evolution.no-candidate" "No successfully checked candidate is available"]
          Just (Candidate (EvolutionContext _ _ before _) _ root) -> pure (beforeRevision before,root)
    CheckedValue _ value <- ExceptT (loadRootValueForChecking root)
    definition <- ExceptT (readRootDefinition code)
    pure (SnapshotInspection base selected root value definition)
  InspectDeclaration (SnapshotInspection _ _ root@(Root contract _ code recipes) _
      definition@(RootDefinition _ _ _ queries tools _ _)) request -> runExceptT $ do
    let source implementation = do
          let name = definingModule implementation
              suffix = "src/" ++ map (\c -> if c == '.' then '/' else c) name ++ ".hs"
              candidates = [bytes | (path,bytes) <- files code,
                relativeName path == suffix || ("/" ++ suffix) `isSuffixOf` relativeName path]
          body <- case candidates of
            [] -> pure Nothing
            [bytes] -> Just <$> checked (either (Left . show) Right (Text.decodeUtf8' bytes))
            _ -> throwE [errorDiagnostic "inspection.source" "Implementation module has multiple captured source files"]
          pure (ImplementationSource (Text.pack name) body)
        unknown kind name = throwE [errorDiagnostic "inspection.unknown" ("Unknown " ++ kind ++ ": " ++ name)]
    case request of
      QueryRequest name supplied -> do
        declaration@(QueryDefinition _ _ implementation _ _ _ _) <- case
          [query | query@(QueryDefinition actual _ _ _ _ _ _) <- queries, actual == name] of
            [query] -> pure query
            _ -> unknown "query" name
        prepared <- ExceptT (Query.prepareRoot root)
        descriptor@(QueryDescriptor _ _ input _) <- ExceptT (pure (Query.selectQuery prepared name))
        result <- traverse (\text -> do
          args <- ExceptT (Dhall.decodeValue (contractShape input) text)
          QueryResult (CheckedValue _ value) _ <- ExceptT
            (Query.queryRoot prepared descriptor (CheckedValue (contractId input) args))
          pure value) supplied
        QueryInspection declaration descriptor <$> source implementation <*> pure result
      ToolRequest name -> do
        declaration@(ToolDefinition _ _ _ _ implementation) <- case
          [tool | tool@(ToolDefinition (MethodName actual) _ _ _ _) <- tools, actual == name] of
            [tool] -> pure tool
            _ -> unknown "tool" name
        prepared <- ExceptT (Tool.prepareTools code)
        (descriptor,model) <- case [(descriptor,model) | Tool.PreparedTool descriptor@(ToolDescriptor (MethodName actual) _ _ _) _ _ model <- prepared, actual == name] of
          [value] -> pure value
          _ -> unknown "tool" name
        ToolInspection declaration descriptor model <$> source implementation
      RecipeRequest name -> do
        recipe@(StoredRecipe _ stateType _ _) <- case [value | Fact (FactId actual) value <- recipes, actual == name] of
          [value] -> pure value
          _ -> unknown "recipe" (Text.unpack name)
        let method = recipeDefinition recipe
        flow <- case method of
          OpenRecipe _ _ -> pure Nothing
          ClosedRecipe entry -> Just <$> ExceptT (Recipe.describeRecipe (SourceRoot contract code definition []) entry Tree)
        pure (RecipeInspection name method stateType flow)
  InspectEvolutionSource workspace@(EvolutionWorkspace kb@(KnowledgeBase repository _) _) -> runExceptT $ do
    live@(WorkspaceSnapshot manifest@(WorkspaceManifest _ _ _ state _) _ _ _) <- ExceptT (Store.readWorkspace workspace)
    (WorkspaceSnapshot (WorkspaceManifest base name explanation _ kind) target _ _,saved,report) <-
      case state of
        Accepted -> (live,SavedCapture,) <$> ExceptT (Store.readArchivedReport workspace)
        _ -> do
          candidate <- ExceptT (Store.loadCheckedCandidate workspace)
          pure $ case candidate of
            Just (Candidate (EvolutionContext _ _ _ snapshot) steps _) -> (snapshot,SavedCapture,Just steps)
            Nothing -> (live,LiveWorkspace,Nothing)
    path <- checked (rootLocation kb)
    previous <- ExceptT (Git.readTreeAt repository base (Subtree path))
    let before = filter (not . isRootMaterial . fst) (files previous)
        after = files target
        changes = [SourceChange key old new | key <- sort (nub (map fst before ++ map fst after)),
          let old = lookup key before, let new = lookup key after, old /= new]
        selectedManifest = if saved == SavedCapture then WorkspaceManifest base name explanation state kind else manifest
    -- Lifecycle state is current; explanation/base/source belong to the labelled capture.
    pure (EvolutionInspection selectedManifest saved report changes)
  where checked = either (throwE . pure . errorDiagnostic "inspection.source") pure
