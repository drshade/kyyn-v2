{-# LANGUAGE GADTs, OverloadedStrings #-}
module QueryExecutionTests (queryExecutionTests) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..))
import qualified Data.ByteString as Bytes
import Effectful (Eff, runEff)
import Effectful.Dispatch.Dynamic (interpret)
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
import Kyyn.Plumbing.Capability.GuestCompilation.Types (CompiledEntry(..))
import Kyyn.Plumbing.Capability.SchemaInspection
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Interpreter.RootExecution
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
      manifest declarations = "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.schemaMetadata\", validator = \"Checks.validate\", queries = " <> declarations <> " }"
      code = tree [(path "src/Queries.hs", "captured query"), (path "kb.dhall", manifest ("[" <> query <> "]"))]
      root = Root rootContract facts code
      sdk = tree [(path "Sdk.hs", "explicit SDK")]
      input = either (error . show) id (checkContract StringType (SchemaMetadata [] [] []))
      output = either (error . show) id (checkContract BoolType (SchemaMetadata [] [] []))
      descriptor = QueryDescriptor "summary" "Summary" input output
      args = CheckedValue (contractId input) (String "hello")
      entry script = CompiledEntry (BuildIdentity "fixture" "fixture") (path "fixture.comb", "") shell
        ["-c", "read -r input; " ++ script] []
      execute compilation queryDescriptor arguments = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
        . compileMock compilation . schemaMock input output . runDhallHandling . runRootStore . runRootExecution sdk $
          queryRoot root queryDescriptor arguments
      unused = error "Invalid query reached compilation"
  discovered <- runEff . runFailure . schemaMock input output . compileMock unused . runProcessExecutionIO . runFileSystemIO scope
    . runDhallHandling . runRootStore . runRootExecution sdk $ discoverQueries root
  unless (discovered == Right (Right [descriptor])) (fail "Query discovery mismatch")
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
        . gateCompiler (entry "exit 97") compilation . schemaMock input output
        . runDhallHandling . runRootStore . runRootExecution sdk $ checkRootCode root
  unusedQuery <- checkCode (Left rejected)
  unless (unusedQuery == Right (Left rejected)) (fail "Unused registered query escaped compilation checking")
  checkedCode <- checkCode (Right (entry "exit 97"))
  unless (checkedCode == Right (Right ())) (fail "Code checking executed a validator/query or failed to check it")
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
schemaMock input output = interpret $ \_ (InspectSchema source) -> do
  let entries = [(relativeName path,bytes) | (path,bytes) <- sourceFiles (schemaSources source)]
  unless (lookup "Queries.hs" entries == Just "captured query" &&
      lookup "Sdk.hs" entries == Just "explicit SDK" && lookup "KyynQueryBindings.hs" entries /= Nothing)
    (error "Query inspection did not use captured code and generated bindings")
  case selectedType source of
    "Queries.Input" -> pure (Right (InspectedSchema input []))
    "Queries.Result" -> pure (Right (InspectedSchema output []))
    _ -> error "Unexpected selected query type"

compileMock :: Either [Diagnostic] CompiledEntry -> Eff (GuestCompilation : es) a -> Eff es a
compileMock result = interpret $ \_ (CompileGuest captured) -> do
  let entries = [(relativeName path,bytes) | (path,bytes) <- sourceFiles captured]
  unless (lookup "Queries.hs" entries == Just "captured query" &&
      lookup "Sdk.hs" entries == Just "explicit SDK" &&
      maybe False (Bytes.isInfixOf "selected = Queries.summary") (lookup "KyynQueryEntry.hs" entries) &&
      all (\name -> lookup name entries /= Nothing) ["KyynQueryBindings.hs","KyynQueryRootCodec.hs","KyynQueryInputCodec.hs","KyynQueryResultCodec.hs"])
    (error "Query compilation did not use captured sources and generated adapter")
  pure result

gateCompiler :: CompiledEntry -> Either [Diagnostic] CompiledEntry -> Eff (GuestCompilation : es) a -> Eff es a
gateCompiler validator query = interpret $ \_ (CompileGuest captured) -> do
  let entries = [(relativeName path,bytes) | (path,bytes) <- sourceFiles captured]
  unless (lookup "KyynQueryBindings.hs" entries /= Nothing) (error "Code-check entry lacks query bindings for shared helper imports")
  if lookup "KyynValidationEntry.hs" entries /= Nothing
    then pure (Right validator)
    else if lookup "KyynQueryEntry.hs" entries /= Nothing
      then pure query
      else error "Unexpected code-check entry"
