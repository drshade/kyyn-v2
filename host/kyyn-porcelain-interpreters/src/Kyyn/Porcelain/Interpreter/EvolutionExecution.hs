{-# LANGUAGE LambdaCase, GADTs, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Porcelain.Interpreter.EvolutionExecution (runEvolutionExecution) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (nub, sort, stripPrefix)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import qualified Kyyn.Domain.StoredSnapshot as Stored
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Porcelain.Protocol.StoredEvolution (executeStoredEvolution)
import Kyyn.Domain.EvolutionReport (EvolutionReport(..), PluginChange(..))
import Kyyn.Domain.Contract (checkRootLayout)
import Kyyn.Domain.Guest (InspectedSchema(..), checkedEntries)
import qualified Kyyn.Types.Guest as G
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (RecipeId(..), FlowEntryRef(..))
import Kyyn.Domain.Plugin (pluginName)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Root (Root(..), pluginPackagesLocation, pluginOriginLocation)
import qualified Kyyn.Domain.Recipe as Value
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionKind(..))
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import qualified Kyyn.Plumbing.Protocol.Plugin as Plugin
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest, EvolutionSelection(..), RecipeReference(..))
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection, describeGuest)
import Kyyn.Plumbing.Protocol.EvolutionSources (captureEvolutionSources)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Protocol.FactProposal (lowerProposal)
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution(..))
import Kyyn.Porcelain.Capability.RootStore (RootStore, checkRecipeValue, loadRootValueForChecking)

runEvolutionExecution
  :: (RootStore :> es, GuestInspection :> es, GuestCompilation :> es,
      GuestExecution :> es, Failure :> es, DhallHandling :> es)
  => Eff (EvolutionExecution : es) a -> Eff es a
runEvolutionExecution = interpret $ \_ -> \case
  EvaluateEvolution captured@(CapturedEvolution
      (EvolutionContext _ _ _ (WorkspaceSnapshot (WorkspaceManifest _ _ explanation _ kind) target change _))
      stored@(Stored.StoredSnapshot _ _ recipes) accepted) -> runExceptT $ do
    let reference (Stored.RecordedRecipe definition _) = case definition of
          Value.OpenRecipe _ name -> OpenState (Text.pack name)
          Value.ClosedRecipe (FlowEntryRef name) -> ClosedFlow name
        references = [reference recipe | Fact _ recipe <- recipes]
    selected <- case kind of
      AdHoc -> pure Nothing
      RecipeBased identity@(RecipeId name) -> case [(reference recipe,state) | Fact (FactId actual) recipe@(Stored.RecordedRecipe _ state) <- recipes, name == actual] of
        [value] -> pure (Just (identity,value))
        _ -> reject "recipe.unknown" "The selected recipe must exist in the stored snapshot"
    let selection modules = EvolutionSelection references (fmap (fst . snd) selected) modules
    lowered <- case selected of
      Nothing -> pure change
      Just _ | not (any ((== "proposal.dhall") . relativeName . fst) (files change)) -> pure change
      Just (_,(_,Stored.RecordedValue _ state)) -> do
        source <- checked "evolution.capture" (captureEvolutionSources (selection (Just [])) target change)
        compiled <- proposed (compileGuest source)
        described <- proposed (describeGuest compiled)
        schema <- case [contract | G.ContractEntry "$evolution.target" (InspectedSchema contract _) <- checkedEntries described] of
          [contract] -> proposed (pure (checkRootLayout contract))
          _ -> reject "evolution.description" "Missing target root description"
        stateContract <- case [contract | G.ContractEntry "$evolution.state" (InspectedSchema contract _) <- checkedEntries described] of
          [contract] -> pure contract
          _ -> reject "evolution.description" "Missing selected recipe state description"
        previous <- proposed (checkRecipeValue stateContract state)
        proposed (lowerProposal schema (Just (stateContract,previous)) change)
    source <- checked "evolution.capture" (captureEvolutionSources (selection Nothing) target lowered)
    compiled <- proposed (compileGuest source)
    described <- proposed (describeGuest compiled)
    (root@(Root schema _ _ states),steps) <- proposed
      (executeStoredEvolution compiled described target (Rationale (Text.pack explanation) []) (fst <$> selected) stored)
    value <- proposed (loadRootValueForChecking root)
    plugins <- proposed (pluginChanges accepted target)
    pure (EvaluatedEvolution captured (After schema) (Value.KnowledgeBase value states) (EvolutionReport plugins steps))

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
