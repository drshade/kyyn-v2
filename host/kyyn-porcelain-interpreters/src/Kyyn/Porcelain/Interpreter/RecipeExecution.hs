{-# LANGUAGE GADTs, OverloadedRecordDot, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.RecipeExecution (runRecipeExecution) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad (unless)
import Data.Aeson (object, toJSON)
import Data.Aeson.Types (parseEither)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Root (Root(..), CheckedValue(..))
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType (DataType(UnitType))
import Kyyn.Domain.CompiledEntry (compiledEntries, entryDescription)
import Kyyn.Domain.Guest (InspectedSchema(..))
import Kyyn.Domain.FileTree (files)
import qualified Kyyn.Types.Guest as G
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest, guestSources, GuestSelection(..), RecipeReference(..))
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection, describeGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeEntry)
import Kyyn.Types.Wire (parseWire)
import Kyyn.Plumbing.Protocol.Tool (decodeFlowValue)
import Kyyn.Porcelain.Capability.RecipeRunStore (RecipeRunStore)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn)
import Kyyn.Plumbing.Protocol.FactProposal (proposalShape, parseProposal)
import Kyyn.Porcelain.Capability.RootStore (RootStore, loadRootValueForChecking)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePluginsFromGuest)
import Kyyn.Porcelain.Capability.PluginRead (PluginRead)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Porcelain.Capability.RecipeExecution
import Kyyn.Porcelain.Protocol.ToolBroker (executeRecordedRecipeProgram)
import Kyyn.Porcelain.Protocol.ModelConfiguration (readModelConfiguration)

runRecipeExecution :: (RecipeRunStore :> es, EvidenceStore :> es, RootStore :> es, PluginPreparation :> es, GuestInspection :> es, GuestCompilation :> es,
  GuestExecution :> es, PluginRead :> es, Failure :> es, Judgement :> es, ModelTurn :> es, DhallHandling :> es)
  => Eff (RecipeExecution : es) a -> Eff es a
runRecipeExecution = interpret $ \_ -> \case
  PrepareRecipeFlow root@(Root contract _ code _) (FlowEntryRef name) (CheckedValue _ stateValue) request -> runExceptT $ do
    let checked = either (throwE . pure . errorDiagnostic "recipe.execution") pure
    source <- checked (guestSources (RecipeEntries [ClosedFlow name]) (files code))
    program <- ExceptT (compileGuest source)
    description <- ExceptT (describeGuest program)
    (entry,actualRoot,inputContract,stateContract) <- case
        [(selected,domain.contract,input.contract,state.contract) | selected <- compiledEntries program description,
         G.RecipeEntry _ actual (G.RecipeContracts domain input state) <- [entryDescription selected], actual == name] of
      [selected] -> pure selected
      _ -> throwE [errorDiagnostic "recipe.description" "Guest did not describe the selected recipe flow"]
    unless (contractId actualRoot == contractId (rootSchema contract))
      (throwE [errorDiagnostic "recipe.root-type" "Recipe flow takes a different Root contract"])
    plugins <- ExceptT (preparePluginsFromGuest code program description)
    _ <- ExceptT (encodeValue (contractShape stateContract) stateValue)
    input <- case request of
      Just authored -> ExceptT (decodeValue (contractShape inputContract) authored)
      Nothing | rootType inputContract == UnitType -> pure (object [])
      Nothing -> throwE [errorDiagnostic "recipe.input-required" "This recipe requires --input DHALL"]
    model <- ExceptT (readModelConfiguration code)
    CheckedValue _ value <- ExceptT (loadRootValueForChecking root)
    output <- ExceptT (Right <$> executeEntry entry (toJSON G.CaptureRecipeGraph))
    graph <- checked (parseWire output >>= parseEither decodeFlowValue)
    pure (PreparedRecipe entry contract stateContract plugins model (toJSON (G.RunRecipe value input stateValue)) graph)
  ExecuteRecipeFlow writer prepared -> runExceptT $ do
    let checked = either (throwE . pure . errorDiagnostic "recipe.execution") pure
    result <- ExceptT (executeRecordedRecipeProgram writer prepared.entry prepared.plugins prepared.model prepared.arguments)
    shape <- checked (proposalShape prepared.rootContract prepared.stateContract)
    _ <- ExceptT (encodeValue shape result)
    checked (parseEither (parseProposal prepared.stateContract) result)
