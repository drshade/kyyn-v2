{-# LANGUAGE GADTs, LambdaCase, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution) where

import Control.Monad (unless, forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (toJSON)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (rootSchema, contractShape, contractId)
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport(..), errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..), CheckedValue(..))
import Kyyn.Domain.Recipe (StoredRecipe(..), recipeDefinition)
import Kyyn.Domain.Query (QueryDefinition(..), QueryDescriptor(..), QueryResult(..))
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.CompiledEntry (compiledEntries, entryDescription)
import Kyyn.Domain.Guest (InspectedSchema(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest, guestSources, GuestSelection(..))
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection, describeGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeEntry)
import Kyyn.Plumbing.Protocol.Validation (decodeReport)
import Kyyn.Plumbing.Protocol.Query (decodeQueryReply)
import Kyyn.Types.Fact (Fact(..))
import qualified Kyyn.Plumbing.Capability.DhallHandling as Dhall
import Kyyn.Porcelain.Capability.RootStore (RootStore, readRootDefinition, loadRootValueForChecking, checkRecipeValue)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution(..))
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePluginsFromGuest, validatePlugins)
import Kyyn.Porcelain.Protocol.ModelConfiguration (readModelConfiguration)
import Kyyn.Porcelain.Protocol.RecipeContracts (inspectRecipeContracts)
import Kyyn.Porcelain.Protocol.OutputBindings (prepareOutputs)
import Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..), PreparedQuery(..))

runRootExecution
  :: (RootStore :> es, GuestCompilation :> es, GuestInspection :> es, GuestExecution :> es,
      Failure :> es, PluginPreparation :> es, Dhall.DhallHandling :> es)
  => Eff (RootExecution : es) a -> Eff es a
runRootExecution = interpret $ \_ -> \case
  PrepareRoot root@(Root contract _ code recipes) -> runExceptT $ do
    definition@(RootDefinition _ _ _ declarations _ _ outputs) <- ExceptT (readRootDefinition code)
    source <- checked "root.sources" (guestSources RootEntries (files code))
    program <- ExceptT (compileGuest source)
    description <- ExceptT (describeGuest program)
    let entries = compiledEntries program description
    validatorEntry <- case [entry | entry <- entries, G.ValidatorEntry _ schema <- [entryDescription entry],
          contractId schema.contract == contractId (rootSchema contract)] of
      [entry] -> pure entry
      _ -> throwE [errorDiagnostic "root.validator" "Guest did not describe the selected Root validator"]
    plugins <- ExceptT (preparePluginsFromGuest code program description)
    _ <- ExceptT (readModelConfiguration code)
    states <- ExceptT (inspectRecipeContracts (SourceRoot contract code definition [])
      [Fact identity (recipeDefinition recipe) | Fact identity recipe <- recipes])
    _ <- forM (zip recipes states) $ \(Fact identity (StoredRecipe _ name expected (CheckedValue fingerprint value)),
      (Fact actual _,actualName,inspected)) -> do
        unless (identity == actual && name == actualName && expected == inspected && fingerprint == contractId inspected)
          (throwE [errorDiagnostic "recipe.state-contract" "Recipe state no longer matches its authored contract"])
        ExceptT (checkRecipeValue inspected value)
    queries <- forM declarations $ \(QueryDefinition name documentation _ _ _ _ _) ->
      case [(entry,input.contract,result.contract) | entry <- entries,
          G.QueryEntry actual (G.QueryContracts schema input result) <- [entryDescription entry],
          actual == Text.pack name, contractId schema.contract == contractId (rootSchema contract)] of
        [(entry,input,result)] -> pure (PreparedQuery (QueryDescriptor name documentation input result) name entry)
        _ -> throwE [errorDiagnostic "query.description" ("Guest did not describe query " ++ name)]
    preparedOutput <- ExceptT (pure (prepareOutputs queries plugins outputs))
    pure (PreparedRoot root "validate" validatorEntry queries plugins preparedOutput)
  ValidateRoot (PreparedRoot root selected entry _ plugins _) -> runExceptT $ do
    CheckedValue _ value <- ExceptT (loadRootValueForChecking root)
    output <- ExceptT (Right <$> executeEntry entry value)
    case decodeReport output of
      Left message -> protocolFailure selected message
      Right (ValidationReport report) -> do
        ValidationReport pluginReport <- ExceptT (validatePlugins plugins)
        pure (ValidationReport (report ++ pluginReport))
  ExecuteQuery (PreparedRoot root _ _ queries _ _) (QueryDescriptor name _ expectedInput expectedResult) (CheckedValue identity arguments) -> runExceptT $ do
    PreparedQuery (QueryDescriptor _ _ input result) selected entry <- case
      [q | q@(PreparedQuery (QueryDescriptor n _ _ _) _ _) <- queries, n == name] of
        [d] -> pure d
        _ -> throwE [errorDiagnostic "query.unknown" ("No query named " ++ name)]
    unless (contractId input == contractId expectedInput && contractId result == contractId expectedResult)
      (throwE [errorDiagnostic "query.contract" (name ++ ": query contracts changed; discover the query again")])
    unless (identity == contractId input)
      (throwE [errorDiagnostic "query.arguments" (name ++ ": arguments belong to a different contract")])
    _ <- ExceptT (Dhall.encodeValue (contractShape input) arguments)
    CheckedValue _ value <- ExceptT (loadRootValueForChecking root)
    output <- ExceptT (Right <$> executeEntry entry (toJSON (G.QueryInvocation value arguments)))
    (valueResult, trace) <- either (protocolFailure selected) pure (decodeQueryReply output)
    checkedResult <- ExceptT (Right <$> Dhall.encodeValue (contractShape result) valueResult)
    case checkedResult of
      Left diagnostics -> protocolFailure selected ("Query result violates its contract: " ++ show diagnostics)
      Right _ -> pure (QueryResult (CheckedValue (contractId result) valueResult) trace)

checked :: String -> Either String a -> ExceptT [Diagnostic] (Eff es) a
checked code = either (throwE . pure . errorDiagnostic code) pure

protocolFailure :: Failure :> es => String -> String -> ExceptT [Diagnostic] (Eff es) a
protocolFailure selected message = ExceptT (raiseFailure
  (RuntimeUnavailable (ProcessDiagnostic ReadOutput (selected ++ ": " ++ message))))
