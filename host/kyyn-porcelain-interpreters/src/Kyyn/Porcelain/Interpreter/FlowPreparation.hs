{-# LANGUAGE GADTs, LambdaCase, OverloadedRecordDot #-}
module Kyyn.Porcelain.Interpreter.FlowPreparation (runFlowPreparation) where

import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (object, toJSON, withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.List (nub)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.CompiledEntry (compiledEntries, entryDescription)
import Kyyn.Domain.Contract (contractShape, rootType)
import Kyyn.Domain.DataType (DataType(UnitType))
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.FlowClosure (FlowDeclaration(..), flowClosure)
import Kyyn.Domain.Guest (InspectedSchema(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Types.Wire (parseWire)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, decodeValue)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection, describeGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeEntry)
import Kyyn.Plumbing.Protocol.Tool (decodeFlowValue)
import Kyyn.Porcelain.Capability.FlowPreparation
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePluginsFromGuest)
import Kyyn.Porcelain.Protocol.ModelConfiguration (readModelConfiguration)

runFlowPreparation :: (GuestCompilation :> es, GuestInspection :> es, GuestExecution :> es,
  PluginPreparation :> es, DhallHandling :> es, Failure :> es)
  => Eff (FlowPreparation : es) a -> Eff es a
runFlowPreparation = interpret $ \_ -> \case
  PrepareInteractiveFlow code definitions selected authored -> runExceptT $ do
    declarations <- ExceptT (pure (flowClosure definitions selected))
    let references = nub [InteractiveFlow name | FlowDeclaration _ (FlowEntryRef name) _ <- declarations]
        checked = either (throwE . pure . errorDiagnostic "flow.preparation") pure
    source <- checked (guestSources (RecipeEntries references) (files code))
    program <- ExceptT (compileGuest source)
    description <- ExceptT (describeGuest program)
    prepared <- traverse (\declaration@(FlowDeclaration _ (FlowEntryRef name) _) -> do
      (entry,input,output) <- case [(candidate,input.contract,output.contract) |
          candidate <- compiledEntries program description,
          G.InteractiveEntry _ actual (G.InteractiveContracts input output) <- [entryDescription candidate], actual == name] of
        [match] -> pure match
        _ -> throwE [errorDiagnostic "flow.description" "Guest did not describe a unique declared interactive entry"]
      captured <- lift (executeEntry entry (toJSON G.CaptureFlowGraph))
      (graph,mermaid) <- checked (parseWire captured >>= parseEither (withObject "captured flow" (\fields ->
        (,) <$> (fields .: "graph" >>= decodeFlowValue) <*> fields .: "mermaid")))
      pure (PreparedFlowEntry declaration entry input output graph mermaid)) declarations
    input <- case prepared of
      first:_ -> case authored of
        Just value -> ExceptT (decodeValue (contractShape first.inputContract) value)
        Nothing | rootType first.inputContract == UnitType -> pure (object [])
        Nothing -> throwE [errorDiagnostic "flow.input-required" "This interactive flow requires an input"]
      [] -> throwE [errorDiagnostic "flow.declaration" "Interactive closure is empty"]
    plugins <- ExceptT (preparePluginsFromGuest code program description)
    model <- ExceptT (readModelConfiguration code)
    pure (PreparedFlow selected input prepared plugins model)
