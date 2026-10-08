{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvolutionExecution (runEvolutionExecution) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (encode)
import Data.Bifunctor (first)
import Data.List (nub, sort, stripPrefix)
import qualified Data.ByteString.Lazy as Bytes
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic, compilerContext)
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport (EvolutionReport(..), PluginChange(..))
import qualified Kyyn.Domain.EvolutionReport as Report
import Kyyn.Domain.Contract (contractId)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Domain.Plugin (pluginName)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..), CheckedValue(..), pluginPackagesLocation, pluginOriginLocation)
import qualified Kyyn.Domain.Recipe as Value
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionKind(..))
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection)
import qualified Kyyn.Plumbing.Protocol.Plugin as Plugin
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeCompiledEntry)
import Kyyn.Plumbing.Protocol.Evolution (evolutionSources, decodeEvolutionReply, mergeEvolutionSources)
import Kyyn.Plumbing.Protocol.FactProposal (lowerProposal)
import Kyyn.Plumbing.Protocol.Recipes (knowledgeBaseValue)
import Kyyn.Plumbing.Protocol.RecipeEvolution (recipeEvolutionSources, recipeEvolutionInput, decodeRecipeEvolutionReply)
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution(..))
import Kyyn.Porcelain.Capability.EvolutionReport (checkEvolutionReport)
import Kyyn.Porcelain.Capability.RootStore (RootStore, readRootDefinition, loadRootValueForChecking)
import Kyyn.Porcelain.Protocol.RecipeBindings (prepareRecipeTypes)
import Kyyn.Porcelain.Protocol.RecipeContracts (inspectRecipeContracts)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation)

runEvolutionExecution
  :: (RootStore :> es, SchemaInspection :> es, ToolPreparation :> es, PluginPreparation :> es,
      GuestCompilation :> es, GuestExecution :> es, Failure :> es, DhallHandling :> es)
  => FileTree -> Eff (EvolutionExecution : es) a -> Eff es a
runEvolutionExecution sdk = interpret $ \_ (EvaluateEvolution captured@(CapturedEvolution
    (EvolutionContext _ _ (Before _ expected)
      (WorkspaceSnapshot (WorkspaceManifest _ _ _ _ kind) before target change _)) source@(Root actual _ acceptedCode recipes) closure
      targetSource@(SourceRoot after preparedCode (RootDefinition _ _ _ _ _ targetSources _) _))) -> runExceptT $ do
  unless (actual == expected) (reject "evolution.before-contract" "Captured input does not match Before's contract")
  RootDefinition _ _ _ _ _ acceptedSources _ <- proposed (readRootDefinition acceptedCode)
  unless (before == acceptedSources) (reject "evolution.before-source" "Captured input does not match Before's source")
  unless (target == preparedCode) (reject "evolution.after-source" "Prepared After does not match the captured target")
  selectedRecipe <- case kind of
    AdHoc -> pure Nothing
    RecipeBased ident@(RecipeId name) -> do
      unless (expected == after && acceptedCode == preparedCode)
        (reject "recipe.artifacts-changed" "Recipe-based evolutions preserve schema, source and configuration; use an ad hoc evolution to change them")
      case [recipe | Fact (FactId actualName) recipe <- recipes, name == actualName] of
        [recipe] -> pure (Just (ident,recipe))
        _ -> reject "recipe.unknown" "The selected recipe must exist in Before"
  CheckedValue _ input <- proposed (loadRootValueForChecking source)
  (stateBindings,stateClosure,importedContracts,_) <- proposed (prepareRecipeTypes sdk before targetSource change)
  old <- checked "evolution.before-closure" (fileTree [(p,b) | (p,b) <- files before, p `elem` (closure ++ stateClosure)])
  lowered <- proposed (lowerProposal expected after
    (fmap (\(_,Value.StoredRecipe _ _ state value) -> (state,value)) selectedRecipe) change)
  combined <- checked "evolution.source-collision" (mergeEvolutionSources [old,targetSources,lowered,stateBindings,sdk])
  prepared <- checked "evolution.prepare" (case selectedRecipe of
    Nothing -> evolutionSources expected after combined
    Just (_,Value.StoredRecipe _ _ contract _) -> recipeEvolutionSources expected contract combined)
  compiled <- proposed (first (map (compilerContext "evolution")) <$> compileGuest prepared)
  let knowledge = Value.KnowledgeBase input [Fact ident (Value.proposedRecipe recipe) | Fact ident recipe <- recipes]
      argument = case selectedRecipe of
        Nothing -> knowledgeBaseValue knowledge
        Just (_,recipe) -> recipeEvolutionInput input recipe
  output <- ExceptT (Right <$> executeCompiledEntry "Evolution.evolution" compiled (Bytes.toStrict (encode argument)))
  reply <- case (case selectedRecipe of
      Nothing -> decodeEvolutionReply output
      Just (ident,_) -> decodeRecipeEvolutionReply ident recipes output) of
    Left message -> ExceptT (raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput
      ("Evolution.evolution: " ++ message))))
    Right (Left failure) -> throwE (EvolutionRejected failure)
    Right (Right result) -> pure result
  let Report.EvolutionObservation (Value.KnowledgeBase _ returnedRecipes) _ = reply
  targetContracts <- proposed (inspectRecipeContracts sdk targetSource
    [Fact ident (Value.proposedDefinition recipe) | Fact ident recipe <- returnedRecipes])
  unless (and [ident == expectedIdent && stateType == expectedType && identity == contractId contract |
    (Fact ident (Value.ProposedRecipe _ stateType identity _), (Fact expectedIdent _,expectedType,contract)) <- zip returnedRecipes targetContracts])
    (reject "recipe.state-contract" "Returned recipe state does not match its target definition")
  let knownStates = importedContracts ++ [(name,contract) | Fact _ (Value.StoredRecipe _ name contract _) <- recipes]
        ++ [(name,contract) | (_,name,contract) <- targetContracts]
  result <- proposed (checkEvolutionReport knownStates expected knowledge after reply)
  plugins <- proposed (pluginChanges acceptedCode preparedCode)
  let (value,EvolutionReport _ steps) = result
  pure (EvaluatedEvolution captured (After after) value (EvolutionReport plugins steps))

pluginChanges :: DhallHandling :> es => FileTree -> FileTree -> Eff es (Either [Diagnostic] [PluginChange])
pluginChanges before after = runExceptT $ traverse change changed
  where
    packages tree = [(name,(path,bytes)) | (file,bytes) <- files tree,
      Just rest <- [stripPrefix (relativeName pluginPackagesLocation ++ "/") (relativeName file)],
      (name,'/':path) <- [break (== '/') rest]]
    old = packages before
    new = packages after
    package name = map snd . filter ((== name) . fst)
    changed = [name | name <- sort (nub (map fst old ++ map fst new)), package name old /= package name new]
    change name = do
      identity <- either (bad . show) pure (pluginName name)
      let earlier = package name old
          later = package name new
      b <- origin name earlier
      a <- origin name later
      paths <- traverse (either bad pure . relativePath)
        [path | path <- sort (nub (map fst earlier ++ map fst later)), lookup path earlier /= lookup path later]
      pure (PluginChange identity b a paths)
    origin _ [] = pure Nothing
    origin name entries = case lookup (relativeName pluginOriginLocation) entries of
      Nothing -> bad ("Changed plugin " ++ name ++ " has no origin.dhall")
      Just bytes -> Just <$> ExceptT (Plugin.decodeOrigin bytes)
    bad = throwE . pure . errorDiagnostic "plugin.report-invalid"

proposed :: Eff es (Either [Diagnostic] a) -> ExceptT PreviewRejection (Eff es) a
proposed = ExceptT . fmap (either (Left . ProposedCodeRejected) Right)

checked :: String -> Either String a -> ExceptT PreviewRejection (Eff es) a
checked code = either (reject code) pure

reject :: String -> String -> ExceptT PreviewRejection (Eff es) a
reject code = throwE . ProposedCodeRejected . pure . errorDiagnostic code
