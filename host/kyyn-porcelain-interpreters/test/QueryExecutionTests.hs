{-# LANGUAGE GADTs, OverloadedStrings, LambdaCase #-}
module QueryExecutionTests (queryExecutionTests) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..))
import Effectful (Eff, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.State.Static.Local (State, modify, runState)
import Kyyn.Domain.Contract
import qualified Kyyn.Types.Contract as D
import qualified Kyyn.Types.Guest as G
import Kyyn.Domain.Guest (checkGuest, CheckedGuest)
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
import Kyyn.Plumbing.Capability.GuestInspection
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Interpreter.RootExecution
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
      manifest declarations = "{ model = None { provider : < OpenAI | Anthropic >, model : Text, credential : Text }, outputs = [] : List { name : Text, description : Text, query : Text, sink : { plugin : Text, instanceName : Text, method : Text } }, views = [] : List { name : Text, description : Text, path : Text }, schemaType = \"Example.Root\", schemaMetadata = \"Example.schemaMetadata\", validator = \"Checks.validate\", queries = " <> declarations <> ", tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"
      code = tree [(path "src/Queries.hs", "captured query"), (path "kb.dhall", manifest ("[" <> query <> "]")), (path "flake.nix","recorded fixture"), (path "flake.lock","recorded lock")]
      root = Root rootContract facts code []
      input = either (error . show) id (checkContract fixtureText (SchemaMetadata [] [] []))
      output = either (error . show) id (checkContract (D.ScalarDescription (D.TypeIdentity "base" "GHC.Types" "Bool" []) D.BoolScalar "bool" []) (SchemaMetadata [] [] []))
      descriptor = QueryDescriptor "summary" "Summary" input output
      args = CheckedValue (contractId input) (String "hello")
      describe c = G.describeContract (descriptionOf c) (metadataOf c) []
      description = either (error . show) id (checkGuest (G.GuestDescription
        [G.ValidatorEntry "validate" (describe (rootSchema rootContract)),
         G.QueryEntry "summary" (G.QueryContracts (describe (rootSchema rootContract)) (describe input) (describe output))] []))
      entry = fixtureProgram
      execute compilation queryDescriptor arguments = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
        . runFixtureExecution shell . gateCompiler compilation . descriptionMock description . runDhallHandling . runRootStore . runPluginPreparation . runRootExecution $ do
          prepared <- prepareRoot root
          either (pure . Left) (\value -> queryRoot value queryDescriptor arguments) prepared
      unused = Right (entry "exit 99")
  discovered <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
    . runFixtureExecution shell . gateCompiler (Right (entry "exit 97")) . descriptionMock description
    . runDhallHandling . runRootStore . runPluginPreparation . runRootExecution $ fmap preparedQueries <$> prepareRoot root
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
  unless (rejection == Right (Left rejected)) (fail "Compiler rejection lost diagnostics")
  let checkCode compilation = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
        . runFixtureExecution shell . gateCompiler compilation . descriptionMock description
        . runDhallHandling . runRootStore . runPluginPreparation . runRootExecution $ fmap preparedQueries <$> prepareRoot root
  unusedQuery <- checkCode (Left rejected)
  unless (unusedQuery == Right (Left rejected)) (fail "Unused registered query escaped compilation checking")
  checkedCode <- checkCode (Right (entry "exit 97"))
  unless (checkedCode == Right (Right [descriptor])) (fail "Code checking executed a validator/query or failed to check it")
  (reused, calls) <- runEff . runState ([] :: [String]) . runFailure . runProcessExecutionIO . runFileSystemIO scope
    . runFixtureExecution shell . gateCompiler (Right (entry "case \"$input\" in *'\"entry\":\"validate\"'*) printf '[]';; *) printf '{\"result\":true,\"trace\":[]}';; esac"))
    . recordExecution . recordCompiler . descriptionMock description . recordInspection
    . runDhallHandling . runRootStore . runPluginPreparation . runRootExecution $ do
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
  let preparation = ["compile", "describe"]
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

descriptionMock :: CheckedGuest -> Eff (GuestInspection : es) a -> Eff es a
descriptionMock description = interpret $ \_ (DescribeGuest _) -> pure (Right description)

gateCompiler :: Either [Diagnostic] CompiledProgram -> Eff (GuestCompilation : es) a -> Eff es a
gateCompiler result = interpret $ \_ (CompileGuest captured) -> do
  let entries = [(relativeName path,bytes) | (path,bytes) <- sourceFiles captured]
  unless (selectedBuild captured == RootEntries && lookup "src/Queries.hs" entries == Just "captured query"
    && lookup "flake.lock" entries == Just "recorded lock") (error "Query preparation changed KB source or lock selection")
  pure result

recordCompiler :: (State [String] :> es, GuestCompilation :> es)
  => Eff (GuestCompilation : es) a -> Eff es a
recordCompiler = interpret $ \_ (CompileGuest sources) -> do
  modify (++ ["compile" :: String])
  compileGuest sources
recordExecution :: (State [String] :> es, GuestExecution :> es)
  => Eff (GuestExecution : es) a -> Eff es a
recordExecution = interpret $ \_ -> \case
  ExecuteGuest {} -> error "Query attempted conversational execution"
  ExecuteCompiled program input -> do
    modify (++ ["execute" :: String])
    executeCompiled program input

recordInspection :: (State [String] :> es, GuestInspection :> es)
  => Eff (GuestInspection : es) a -> Eff es a
recordInspection = interpret $ \_ (DescribeGuest program) -> do
  modify (++ ["describe" :: String])
  describeGuest program
