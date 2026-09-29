{-# LANGUAGE GADTs, OverloadedStrings, LambdaCase #-}
module QueryExecutionTests (queryExecutionTests) where

import Kyyn.Domain.Curation (emptyCurationRegister)
import Control.Monad (unless, forM_)
import Data.Aeson (Value(..))
import Effectful (Eff, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.State.Static.Local (State, modify, runState)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Failure
import Kyyn.Domain.FileTree
import Kyyn.Domain.Path
import Kyyn.Domain.Query
import Kyyn.Domain.Root
import Kyyn.Types.SchemaMetadata
import Kyyn.Types.Query (ReadAccess(..))
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution
import GuestFixture
import Kyyn.Plumbing.Capability.SchemaInspection
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Interpreter.RootExecution
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.RootStore
import System.Directory (findExecutable)
import System.IO.Temp (withSystemTempDirectory)

queryExecutionTests :: RootContract -> FileTree -> IO ()
queryExecutionTests rootContract facts = withSystemTempDirectory "kyyn-query-execution" $ \directory -> do
  scope <- either fail pure (directoryScope directory)
  shell <- findExecutable "sh" >>= maybe (fail "sh required for query reply fixtures") pure
  let path = either error id . relativePath
      tree = either error id . fileTree
      query = "{ name = \"summary\", description = \"Summary\", implementation = \"Queries.summary\", inputType = \"Queries.Input\", inputMetadata = \"Queries.inputMetadata\", resultType = \"Queries.Result\", resultMetadata = \"Queries.resultMetadata\" }"
      manifest declarations = "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.schemaMetadata\", validator = \"Checks.validate\", queries = " <> declarations <> ", tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"
      code = tree [(path "src/Queries.hs", "captured query"), (path "kb.dhall", manifest ("[" <> query <> "]"))]
      root = Root rootContract facts code emptyCurationRegister []
      sdk = tree [(path "Sdk.hs", "explicit SDK")]
      input = either (error . show) id (checkContract StringType (SchemaMetadata [] [] []))
      output = either (error . show) id (checkContract BoolType (SchemaMetadata [] [] []))
      descriptor = QueryDescriptor "summary" "Summary" input output
      args = CheckedValue (contractId input) (String "hello")
      entry = fixtureProgram
      execute compilation queryDescriptor arguments = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
        . runFixtureExecution shell . gateCompiler (entry "printf '[]'") compilation . schemaMock input output . runDhallHandling . runRootStore . runPluginPreparation sdk . runToolPreparation sdk . runRootExecution sdk $ do
          prepared <- prepareRoot root
          either (pure . Left) (\value -> queryRoot value queryDescriptor arguments) prepared
      unused = Right (entry "exit 99")
  discovered <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
    . runFixtureExecution shell . gateCompiler (entry "exit 97") (Right (entry "exit 97")) . schemaMock input output
    . runDhallHandling . runRootStore . runPluginPreparation sdk . runToolPreparation sdk . runRootExecution sdk $ fmap preparedQueries <$> prepareRoot root
  unless (discovered == Right (Right [descriptor])) (fail "Prepared query discovery mismatch")
  success <- execute (Right (entry "printf '{\"result\":true,\"trace\":[{\"tag\":\"Collection\",\"collection\":\"todos\"}]}'")) descriptor args
  unless (success == Right (Right (QueryResult (CheckedValue (contractId output) (Bool True)) [CollectionRead "todos"])))
    (fail (show success))
  forM_ [(QueryDescriptor "absent" "" input output,args),
      (QueryDescriptor "summary" "" output output,args),
      (QueryDescriptor "summary" "" input input,args),
      (descriptor,CheckedValue (contractId output) (Bool True)),
      (descriptor,CheckedValue (contractId input) (Bool True))] $ \(d,a) -> do
    response <- execute unused d a
    case response of Right (Left _) -> pure (); _ -> fail "Invalid query/arguments reached compilation"
  let rejected = [errorDiagnostic "guest.compiler-rejected" "bad query"]
  rejection <- execute (Left rejected) descriptor args
  unless (rejection == Right (Left [errorDiagnostic "query.compiler-rejected" "bad query"])) (fail "Compiler rejection lost diagnostics")
  let checkCode compilation = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
        . runFixtureExecution shell . gateCompiler (entry "exit 97") compilation . schemaMock input output
        . runDhallHandling . runRootStore . runPluginPreparation sdk . runToolPreparation sdk . runRootExecution sdk $ fmap preparedQueries <$> prepareRoot root
  unusedQuery <- checkCode (Left rejected)
  unless (unusedQuery == Right (Left [errorDiagnostic "query.compiler-rejected" "bad query"])) (fail "Unused registered query escaped compilation checking")
  checkedCode <- checkCode (Right (entry "exit 97"))
  unless (checkedCode == Right (Right [descriptor])) (fail "Code checking executed a validator/query or failed to check it")
  (reused, calls) <- runEff . runState ([] :: [String]) . runFailure . runProcessExecutionIO . runFileSystemIO scope
    . runFixtureExecution shell . gateCompiler (entry "printf '[]'") (Right (entry "printf '{\"result\":true,\"trace\":[]}'"))
    . recordExecution . recordCompiler . schemaMock input output . recordInspection
    . runDhallHandling . runRootStore . runPluginPreparation sdk . runToolPreparation sdk . runRootExecution sdk $ do
      prepared <- prepareRoot root >>= either (error . show) pure
      unless (preparedRoot prepared == root && preparedQueries prepared == [descriptor])
        (error "Preparation changed the root or its descriptors")
      forM_ [1 :: Int, 2] $ \_ -> do
        report <- validateRoot prepared
        unless (report == Right (ValidationReport [])) (error "Prepared validator changed its result")
        result <- queryRoot prepared descriptor args
        unless (result == Right (QueryResult (CheckedValue (contractId output) (Bool True)) []))
          (error "Prepared query changed its result")
      _ <- prepareRoot root >>= either (error . show) pure
      pure ()
  let preparation = ["compile:KyynValidationEntry.hs", "inspect:Queries.Input", "inspect:Queries.Result", "compile:KyynQueryEntry.hs"]
  unless (reused == Right () && calls == preparation ++ replicate 4 "execute" ++ preparation)
    (fail ("Prepared execution rebuilt code or a separate preparation reused hidden state: " ++ show calls))
  forM_ ["printf '{}'", "printf '{\"result\":\"wrong type\",\"trace\":[]}'"] $ \script -> do
    response <- execute (Right (entry script)) descriptor args
    case response of
      Left (RuntimeUnavailable (ProcessDiagnostic ReadOutput _)) -> pure ()
      _ -> fail ("Bad query reply did not remain Failure: " ++ show response)
  crashed <- execute (Right (entry "exit 17")) descriptor args
  case crashed of
    Left (RuntimeUnavailable (ProcessDiagnostic WaitForExit _)) -> pure ()
    _ -> fail "Query process failure misclassified"
  forM_ ["[" <> query <> ", " <> query <> "]", "[] : List Text"] $ \declarations -> do
    let badCode = tree [(path "kb.dhall", manifest declarations)]
    bad <- runEff . runDhallHandling . runRootStore $ readRootDefinition badCode
    case bad of Left _ -> pure (); _ -> fail "Malformed query registration accepted"
  putStrLn "Query discovery, contract/argument rejection, captured code and operational failure checks passed."

schemaMock :: CheckedContract -> CheckedContract -> Eff (SchemaInspection : es) a -> Eff es a
schemaMock input output = interpret $ \_ -> \case
  InspectType {} -> error "Unexpected plain type inspection"
  InspectPluginFunction {} -> error "Unexpected plugin signature inspection"
  InspectSchema source -> do
    let entries = [(relativeName path,bytes) | (path,bytes) <- sourceFiles (schemaSources source)]
    unless (lookup "Queries.hs" entries == Just "captured query" &&
        lookup "Sdk.hs" entries == Just "explicit SDK" && lookup "KyynQueryBindings.hs" entries /= Nothing)
      (error "Query inspection did not use captured code and generated bindings")
    case selectedType source of
      "Queries.Input" -> pure (Right (InspectedSchema input []))
      "Queries.Result" -> pure (Right (InspectedSchema output []))
      _ -> error "Unexpected selected query type"

gateCompiler :: CompiledProgram -> Either [Diagnostic] CompiledProgram -> Eff (GuestCompilation : es) a -> Eff es a
gateCompiler validator query = interpret $ \_ -> \case
  CompileGuest captured -> do
    let entries = [(relativeName path,bytes) | (path,bytes) <- sourceFiles captured]
    unless (lookup "KyynQueryBindings.hs" entries /= Nothing) (error "Code-check entry lacks query bindings for shared helper imports")
    if lookup "KyynValidationEntry.hs" entries /= Nothing
      then pure (Right validator)
      else if lookup "KyynQueryEntry.hs" entries /= Nothing
        then pure query
        else error "Unexpected code-check entry"

recordCompiler :: (State [String] :> es, GuestCompilation :> es)
  => Eff (GuestCompilation : es) a -> Eff es a
recordCompiler = interpret $ \_ -> \case
  CompileGuest sources -> do
    modify (++ ["compile:" ++ relativeName (selectedEntry sources)])
    compileGuest sources
recordExecution :: (State [String] :> es, GuestExecution :> es)
  => Eff (GuestExecution : es) a -> Eff es a
recordExecution = interpret $ \_ -> \case
  ExecuteGuest {} -> error "Query attempted conversational execution"
  ExecuteCompiled program input -> do
    modify (++ ["execute" :: String])
    executeCompiled program input

recordInspection :: (State [String] :> es, SchemaInspection :> es)
  => Eff (SchemaInspection : es) a -> Eff es a
recordInspection = interpret $ \_ -> \case
  InspectType {} -> error "Unexpected plain type inspection"
  InspectPluginFunction {} -> error "Unexpected plugin signature inspection"
  InspectSchema source -> do
    modify (++ ["inspect:" ++ selectedType source])
    inspectSchema source
