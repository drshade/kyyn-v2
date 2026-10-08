{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution) where

import Control.Monad (unless, forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (encode, object, (.=))
import Data.Bifunctor (first)
import qualified Data.ByteString as Strict
import qualified Data.ByteString.Lazy as Bytes
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (rootType, rootSchema, contractShape, contractId)
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport(..), errorDiagnostic, compilerContext)
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..), CheckedValue(..))
import Kyyn.Domain.Recipe (StoredRecipe(..), recipeDefinition)
import Kyyn.Domain.Query (QueryDefinition(..), QueryDescriptor(..), QueryResult(..))
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Path (RelativePath)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeCompiledEntry)
import Kyyn.Plumbing.Protocol.Validation (validationSources, decodeReport)
import Kyyn.Plumbing.Protocol.Query (queryBindings, querySources, decodeQueryReply)
import Kyyn.Types.Fact (Fact(..))
import qualified Kyyn.Plumbing.Capability.DhallHandling as Dhall
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import Kyyn.Porcelain.Capability.RootStore (RootStore, readRootDefinition, loadRootValueForChecking, checkRecipeValue)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution(..))
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePlugins, validatePlugins)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation, prepareTools)
import Kyyn.Porcelain.Protocol.RecipeContracts (inspectRecipeContracts)
import Kyyn.Porcelain.Protocol.OutputBindings (prepareOutputs)
import Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..), PreparedQuery(..))

runRootExecution
  :: (RootStore :> es, GuestCompilation :> es, GuestExecution :> es, Failure :> es, PluginPreparation :> es, ToolPreparation :> es,
      Schema.SchemaInspection :> es, Dhall.DhallHandling :> es)
  => FileTree -> Eff (RootExecution : es) a -> Eff es a
runRootExecution sdk = interpret $ \_ -> \case
  PrepareRoot root@(Root contract _ code recipes) -> runExceptT $ do
    plugins <- ExceptT (preparePlugins code)
    _ <- ExceptT (prepareTools code plugins)
    definition@(RootDefinition _ _ validator declarations _ authored outputs) <- ExceptT (readRootDefinition code)
    states <- ExceptT (inspectRecipeContracts sdk (SourceRoot contract code definition [])
      [Fact identity (recipeDefinition recipe) | Fact identity recipe <- recipes])
    _ <- forM (zip recipes states) $ \(Fact identity (StoredRecipe _ name expected (CheckedValue fingerprint value)),
      (Fact actual _,actualName,inspected)) -> do
        unless (identity == actual && name == actualName && expected == inspected && fingerprint == contractId inspected)
          (throwE [errorDiagnostic "recipe.state-contract" "Recipe state no longer matches its authored contract"])
        ExceptT (checkRecipeValue inspected value)
    bindings <- checked "query.bindings" (queryBindings contract)
    validation <- checked "root.validation-source"
      (validationSources (rootType (rootSchema contract)) validator (bindings : files authored ++ files sdk))
    validatorEntry <- ExceptT (first (map (compilerContext "validator")) <$> compileGuest validation)
    queries <- forM declarations $ \declaration@(QueryDefinition _ _ selected _ _ _ _) -> do
      descriptor@(QueryDescriptor _ _ input result) <- inspectQuery (bindings : files authored ++ files sdk) declaration
      sources <- checked "query.source"
        (querySources contract (rootType input) (rootType result) selected (files authored ++ files sdk))
      entry <- ExceptT (first (map (compilerContext "query")) <$> compileGuest sources)
      pure (PreparedQuery descriptor selected entry)
    preparedOutput <- prepareOutputs sdk authored code queries plugins outputs
    pure (PreparedRoot root validator validatorEntry queries plugins preparedOutput)
  ValidateRoot (PreparedRoot root selected entry _ plugins _) -> runExceptT $ do
    CheckedValue _ value <- ExceptT (loadRootValueForChecking root)
    output <- ExceptT (Right <$> executeCompiledEntry selected entry (Bytes.toStrict (encode value)))
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
    output <- ExceptT (Right <$> executeCompiledEntry selected entry
      (Bytes.toStrict (encode (object ["root" .= value, "arguments" .= arguments]))))
    (valueResult, trace) <- either (protocolFailure selected) pure (decodeQueryReply output)
    checkedResult <- ExceptT (Right <$> Dhall.encodeValue (contractShape result) valueResult)
    case checkedResult of
      Left diagnostics -> protocolFailure selected ("Query result violates its contract: " ++ show diagnostics)
      Right _ -> pure (QueryResult (CheckedValue (contractId result) valueResult) trace)

checked :: String -> Either String a -> ExceptT [Diagnostic] (Eff es) a
checked code = either (throwE . pure . errorDiagnostic code) pure

inspectQuery :: Schema.SchemaInspection :> es
  => [(RelativePath, Strict.ByteString)] -> QueryDefinition -> ExceptT [Diagnostic] (Eff es) QueryDescriptor
inspectQuery sources (QueryDefinition name description _ input inputMetadata result resultMetadata) = do
  inputSource <- checked "query.input-contract" (Schema.schemaSource sources input inputMetadata)
  resultSource <- checked "query.result-contract" (Schema.schemaSource sources result resultMetadata)
  Schema.InspectedSchema inputContract _ <- ExceptT (first (map (compilerContext "query")) <$> Schema.inspectSchema inputSource)
  Schema.InspectedSchema resultContract _ <- ExceptT (first (map (compilerContext "query")) <$> Schema.inspectSchema resultSource)
  pure (QueryDescriptor name description inputContract resultContract)

protocolFailure :: Failure :> es => String -> String -> ExceptT [Diagnostic] (Eff es) a
protocolFailure selected message = ExceptT (raiseFailure
  (RuntimeUnavailable (ProcessDiagnostic ReadOutput (selected ++ ": " ++ message))))
