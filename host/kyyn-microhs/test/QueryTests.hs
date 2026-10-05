-- Typed query composition, binding generation, trace and reply decoding.
-- --pure skips compilation; full mode checks selected metadata and actual MicroHs
-- requests with dependent collection reads. No provider or publication.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Kyyn.Types.KnowledgeBase as KB

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runEff, runPureEff)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Path
import Kyyn.Domain.Query
import Kyyn.Domain.Root
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.Query (ReadAccess(..))
import Kyyn.Types.SchemaMetadata
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Protocol.Query
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.MicroHs.Toolchain
import Kyyn.MicroHs.Interpreter.GuestCompilation
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.MicroHs.Interpreter.SchemaInspection
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Interpreter.RootExecution
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.RootStore
import qualified QueryCore
import System.Environment (getArgs, getEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = do
  QueryCore.main
  pureTests
  args <- getArgs
  case args of
    ["--pure"] -> pure ()
    [] -> integration
    _ -> fail "usage: queries [--pure]"

pureTests :: IO ()
pureTests = do
  unless (decodeQueryReply "{\"result\":true,\"trace\":[{\"tag\":\"Fact\",\"collection\":\"people\",\"factId\":\"missing\"}]}"
      == Right (Bool True, [FactRead "people" (FactId "missing")])) (fail "Read trace decoding failed")
  forM_ ["{}", "null", "{\"result\":true,\"trace\":[{\"tag\":\"Other\"}]}",
    "{\"result\":true,\"trace\":[{\"tag\":\"Collection\",\"collection\":\"c\",\"factId\":\"x\"}]}",
    "{\"result\":true,\"trace\":false}", "{\"result\":true,\"trace\":[]} trailing"] $ \value ->
      case decodeQueryReply value of Left _ -> pure (); Right _ -> fail "Malformed query reply accepted"
  root <- either (fail . show) pure (checkContract rootTypeFixture rootMetadata >>= checkRootLayout)
  (_,bindings) <- either fail pure (queryBindings root)
  unless (Bytes.isInfixOf "tasks = SDK.CollectionBinding \"to-dos\"" bindings &&
      Bytes.isInfixOf "Schema.Root values _" bindings && Bytes.isInfixOf "Schema.Root _ values" bindings)
    (fail "Generated collection identity/selector mismatch")
  let path = either error id . relativePath
  forM_ ["KyynQueryBindings.hs", "KyynQueryEntry.hs", "KyynQueryInputCodec.hs"] $ \collision ->
    case querySources root StringType (OptionalType personType) "Queries.ownerOf" [(path collision,"collision")] of
      Left _ -> pure ()
      Right _ -> fail "Reserved query source collision accepted"
  putStrLn "Query reply and binding generation checks passed."

personType :: DataType
personType = Algebraic "Schema.Person" [] [Constructor "Schema.Person" [(Just "name",StringType)]]

rootTypeFixture :: DataType
rootTypeFixture = Algebraic "Schema.Root" [] [Constructor "Schema.Root"
  [(Just "tasks", factList todo), (Just "people", factList personType)]]
  where
    todo = Algebraic "Schema.Todo" [] [Constructor "Schema.Todo" [(Just "title",StringType),(Just "owner",sdkFactIdType)]]
    factList t = ListType (Algebraic "Kyyn.Types.Fact.Fact" [t]
      [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,sdkFactIdType),(Nothing,t)]])

rootMetadata :: SchemaMetadata
rootMetadata = SchemaMetadata [] []
  [CollectionDecl "to-dos" "tasks" [("owner","people")], CollectionDecl "people" "people" []]

integration :: IO ()
integration = withSystemTempDirectory "kyyn-queries" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  compiler <- getEnv "KYYN_TEST_TOOLCHAIN"
  scope <- either fail pure (directoryScope temporary)
  toolchain <- GuestToolchain <$> either fail pure (directoryScope compiler)
  let path = either error id . relativePath
      tree = either error id . fileTree
      utf8 = Text.encodeUtf8 . Text.pack
      load base file = (,) (path file) <$> Bytes.readFile (repo </> base </> file)
  authored <- mapM (load "host/kyyn-microhs/test/query") ["Schema.hs","Queries.hs","Validate.hs"]
  sdkFiles <- sequence ([load "shared/kyyn-types/src" ("Kyyn/Types/" ++ name ++ ".hs") |
      name <- ["SchemaMetadata","Fact","Program","Query","Diagnostic"]] ++
    [load "guest/kyyn-sdk/src" ("Kyyn/" ++ name ++ ".hs") | name <- ["Schema","Query","Validation"]] ++
    [load "guest/kyyn-runtime/src" ("Kyyn/Runtime/" ++ name ++ ".hs") | name <- ["Json","SchemaMetadata","Query","Validation"]] ++
    [load "vendor/json" name | name <- ["Text/JSON/Types.hs","Text/JSON/String.hs"]])
  let sdk = tree sdkFiles
      registration = "{ name = \"owner\", description = \"Look up the task owner\", implementation = \"Queries.ownerOf\", inputType = \"Schema.Input\", inputMetadata = \"Schema.inputMetadata\", resultType = \"Schema.Result\", resultMetadata = \"Schema.resultMetadata\" }"
      manifest = "{ schemaType = \"Schema.Root\", schemaMetadata = \"Schema.schemaMetadata\", validator = \"Validate.validate\", queries = [" ++ registration ++ "], tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"
      code = tree ((path "kb.dhall",utf8 manifest) : [(path ("src/" ++ relativeName p),b) | (p,b) <- authored])
  contract <- either (fail . show) pure (checkContract rootTypeFixture rootMetadata >>= checkRootLayout)
  let values = object ["tasks" .= [object ["id" .= ("todo-001" :: String), "value" .= object
        ["title" .= ("Review" :: String), "owner" .= ("person-001" :: String)]]],
        "people" .= [object ["id" .= ("person-001" :: String), "value" .= object ["name" .= ("Ada 🦋" :: String)]]]]
  root <- either (fail . show) pure (runPureEff . runDhallHandling . runRootStore $
    materializeRoot contract code (KB.KnowledgeBase (CheckedValue (contractId (rootSchema contract)) values) []))
  discovery <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestExecution toolchain . runGuestCompilation toolchain Nothing
    . runDhallHandling . runSchemaInspectionIO toolchain Nothing . runRootStore . runPluginPreparation sdk . runToolPreparation sdk . runRootExecution sdk $ prepareRoot root
  prepared <- either (fail . show) (either (fail . show) pure) discovery
  descriptor@(QueryDescriptor _ _ input result) <- case preparedQueries prepared of
    [d] -> pure d
    _ -> fail ("Query discovery failed: " ++ show discovery)
  unless (rootType input == StringType && rootType result == OptionalType personType)
    (fail "Named query types were not inspected")
  unless (metadataOf result == SchemaMetadata [RoleDecl "label" "Person's name" Title]
    [FieldRole "Schema.Person" "name" "label"] []) (fail "Query result metadata lost or copied from Root")
  response <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestExecution toolchain . runGuestCompilation toolchain Nothing
    . runDhallHandling . runSchemaInspectionIO toolchain Nothing . runRootStore . runPluginPreparation sdk . runToolPreparation sdk . runRootExecution sdk $
      queryRoot prepared descriptor (CheckedValue (contractId input) (String "Review"))
  let expected = QueryResult (CheckedValue (contractId result)
        (object ["tag" .= ("Some" :: String), "value" .= object ["name" .= ("Ada 🦋" :: String)]]))
        [CollectionRead "to-dos", FactRead "people" (FactId "person-001")]
  unless (response == Right (Right expected)) (fail ("Query execution failed: " ++ show response))
  badSources <- either fail pure (querySources contract StringType (OptionalType personType) "Queries.ownerOf"
    ([(p, if relativeName p == "Queries.hs" then utf8 (unlines
      ["module Queries where", "import KyynQueryBindings", "import Kyyn.Query (readCollection)",
       "import Kyyn.Schema", "import qualified Schema", "ownerOf :: String -> Query [Fact Schema.Person]",
       "ownerOf _ = readCollection tasks"]) else b) | (p,b) <- authored] ++ files sdk))
  rejected <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestCompilation toolchain Nothing $ compileGuest badSources
  case rejected of
    Right (Left _) -> pure ()
    Left failure -> fail (show failure)
    Right (Right _) -> fail "Wrong typed collection was not rejected"
  putStrLn "Real MicroHs query discovery, selected-root execution, Unicode result/trace and mismatched collection rejection passed."
