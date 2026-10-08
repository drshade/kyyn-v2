{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.RecipeExecution (runRecipeExecution) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad (unless)
import qualified Data.Text as Text
import Data.Aeson (object)
import Data.Aeson.Types (parseEither)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Root (Root(..), CheckedValue(..))
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType (DataType(UnitType))
import Kyyn.Domain.Recipe (RecipeSignature(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection, inspectRecipeFunction)
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, mergeEvolutionSources)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn)
import Kyyn.Plumbing.Protocol.Recipe (recipeSources, recipeInputValue)
import Kyyn.Plumbing.Protocol.FactProposal (proposalShape, parseProposal)
import Kyyn.Porcelain.Capability.RootStore (RootStore, loadRootValueForChecking)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation, prepareToolBindings)
import Kyyn.Porcelain.Capability.PluginRead (PluginRead)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Porcelain.Capability.RecipeExecution
import Kyyn.Porcelain.Protocol.ToolBindings (pluginBindings)
import Kyyn.Porcelain.Protocol.ToolBroker (executeToolProgram)
import Kyyn.Porcelain.Protocol.ModelConfiguration (readModelConfiguration)

runRecipeExecution :: (EvidenceStore :> es, RootStore :> es, ToolPreparation :> es, SchemaInspection :> es, GuestCompilation :> es,
  GuestExecution :> es, PluginRead :> es, Failure :> es, Judgement :> es, ModelTurn :> es, DhallHandling :> es)
  => Eff (RecipeExecution : es) a -> Eff es a
runRecipeExecution = interpret $ \_ (ExecuteRecipeFlow root@(Root contract _ code _) plugins entry@(FlowEntryRef name) (CheckedValue stateIdentity stateValue) request) -> runExceptT $ do
  (sources,_) <- ExceptT (prepareToolBindings code plugins)
  let (interfaces,instances) = pluginBindings plugins
      checked = either (throwE . pure . errorDiagnostic "recipe.execution") pure
  bindings <- checked (evolutionBindings contract contract)
  inspectionSources <- checked (mergeEvolutionSources [sources,bindings])
  signature@(RecipeSignature actualRoot inputType stateType) <- ExceptT (inspectRecipeFunction inspectionSources (Text.unpack name))
  unless (actualRoot == rootType (rootSchema contract)) (throwE [errorDiagnostic "recipe.root-type" "Recipe flow takes a different root type"])
  inputContract <- ExceptT (pure (checkContract inputType (SchemaMetadata [] [] [])))
  stateContract <- ExceptT (pure (checkContract stateType (SchemaMetadata [] [] [])))
  unless (stateIdentity == contractId stateContract) (throwE [errorDiagnostic "recipe.state-contract" "Stored recipe state differs from the flow's state type"])
  _ <- ExceptT (encodeValue (contractShape stateContract) stateValue)
  input <- case request of
    Just source -> ExceptT (decodeValue (contractShape inputContract) source)
    Nothing | inputType == UnitType -> pure (object [])
    Nothing -> throwE [errorDiagnostic "recipe.input-required" "This recipe requires --input DHALL"]
  programSources <- checked (recipeSources contract signature entry interfaces instances sources)
  program <- ExceptT (compileGuest programSources)
  model <- ExceptT (readModelConfiguration code)
  CheckedValue _ value <- ExceptT (loadRootValueForChecking root)
  result <- ExceptT (executeToolProgram program plugins model [] (recipeInputValue value input stateValue))
  shape <- checked (proposalShape contract stateContract)
  _ <- ExceptT (encodeValue shape result)
  checked (parseEither (parseProposal stateContract) result)
