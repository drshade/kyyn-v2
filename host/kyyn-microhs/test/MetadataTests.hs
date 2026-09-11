{-# LANGUAGE DataKinds, OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Aeson as Aeson
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runEff, runPureEff)
import Kyyn.Domain.Root (CheckedValue(..))
import Kyyn.Domain.Diagnostic (Diagnostic(Diagnostic), Severity(..), DiagnosticLocation(..), ValidationReport(..), CheckResult(..), checkReport)
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.Interpreter.RootExecution
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Types.SchemaMetadata
import Kyyn.Domain.Path
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Protocol.Validation (decodeReport)
import Kyyn.Plumbing.Protocol.Query (queryBindings)
import Kyyn.Plumbing.Capability.SchemaInspection.Metadata
import Kyyn.Domain.Contract (metadataOf, rootType, checkRootLayout)
import Kyyn.Plumbing.Capability.SchemaInspection
import Kyyn.MicroHs.Interpreter.SchemaInspection
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)
import Kyyn.Plumbing.Capability.ProcessExecution
import ContractTests (contractTests)
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.MicroHs.Interpreter.GuestCompilation
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import System.Environment (getArgs, getEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = do
  codecTests
  reportTests
  contractTests
  args <- getArgs
  case args of
    ["--codec-only"] -> pure ()
    [] -> integration
    _ -> fail "usage: metadata [--codec-only]"

codecTests :: IO ()
codecTests = do
  unless (decodeMetadata "{\"roles\":[],\"fieldRoles\":[],\"collections\":[]}"
    == Right (SchemaMetadata [] [] [])) (fail "empty metadata round trip")
  forM_ ["{}", "null", "{", "{\"roles\":[],\"fieldRoles\":[],\"collections\":[],\"extra\":true}",
    "{\"roles\":[],\"fieldRoles\":[],\"collections\":[]} trailing",
    "{\"roles\":[],\"fieldRoles\":[],\"collections\":[{\"collection\":\"c\",\"rootField\":\"c\",\"references\":[{\"field\":false,\"collection\":\"c\"}]}]}",
    "{\"roles\":[{\"name\":\"r\",\"description\":\"d\",\"affordance\":{\"tag\":\"Unknown\"}}],\"fieldRoles\":[],\"collections\":[]}"] $ \input ->
      case decodeMetadata input of
        Left _ -> pure ()
        Right value -> fail ("invalid metadata accepted: " ++ show value)
  case decodeMetadata (Bytes.pack [255]) of
    Left _ -> pure ()
    Right _ -> fail "invalid UTF-8 accepted"
  forM_ ["schemaMetadata", "Schema.x;bad", "Schema..x", "Schema.X"] $ \name ->
    case metadataAdapter name of
      Left _ -> pure ()
      Right _ -> fail ("invalid export accepted: " ++ name)
  putStrLn "Metadata codec and adapter checks passed."
  reserved <- either fail pure (relativePath "KyynMetadataEntry.hs")
  case schemaSource [(reserved,"collision")] "Authored.Root" "Authored.schemaMetadata" of
    Left _ -> pure ()
    Right _ -> fail "reserved adapter path collision accepted"
  case schemaSource [] "Authored.Root" "notQualified" of
    Left _ -> pure ()
    Right _ -> fail "unqualified metadata export accepted"

integration :: IO ()
integration = withSystemTempDirectory "kyyn-metadata" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  scope <- either fail pure (directoryScope temporary)
  toolchain <- GuestToolchain <$> either fail pure (directoryScope (repo </> "vendor/MicroHs"))
  let path = either error id . relativePath
      utf8 = Text.encodeUtf8 . Text.pack
  files <- mapM (\(base, file) -> (,) (path file) <$> Bytes.readFile (repo </> base </> file))
    [("host/kyyn-microhs/test/metadata", "Authored.hs"),
     ("guest/kyyn-sdk/src", "Kyyn/Schema.hs"),
     ("shared/kyyn-types/src", "Kyyn/Types/SchemaMetadata.hs"),
     ("shared/kyyn-types/src", "Kyyn/Types/Fact.hs"),
     ("guest/kyyn-runtime/src", "Kyyn/Runtime/SchemaMetadata.hs"),
     ("guest/kyyn-runtime/src", "Kyyn/Runtime/Json.hs"),
     ("vendor/json", "Text/JSON/Types.hs"), ("vendor/json", "Text/JSON/String.hs")]
  selected <- either fail pure (schemaSource files "Authored.Root" "Authored.schemaMetadata")
  let sources = schemaSources selected
  result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestCompilation toolchain
    . runSchemaInspectionIO toolchain $ inspectSchema selected
  let expected = SchemaMetadata
        [RoleDecl "task-name" "Tasks in München 🦋" Title,
         RoleDecl "date" "When" Timeline, RoleDecl "status" "State" Badge]
        [FieldRole "Authored.Todo" "title" "task-name"]
        [CollectionDecl n n [("owner", "people")] | n <- ["todos", "people"]]
  InspectedSchema checked closure <- either (fail . show) (either (fail . show) pure) result
  unless (path "Authored.hs" `elem` closure && path "Kyyn/Types/Fact.hs" `elem` closure &&
      path "Kyyn/Runtime/Json.hs" `notElem` closure) (fail ("Wrong schema import closure: " ++ show closure))
  rootContract <- either (fail . show) pure (checkRootLayout checked)
  unless (metadataOf checked == expected) (fail (show result))
  unsupported <- either fail pure (schemaSource ((path "Unsupported.hs", "module Unsupported where\ndata Root = Root { recursive :: Root }\n") : files)
    "Unsupported.Root" "Authored.schemaMetadata")
  rejectedSchema <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestCompilation toolchain
    . runSchemaInspectionIO toolchain $ inspectSchema unsupported
  case rejectedSchema of
    Right (Left _) -> pure ()
    _ -> fail ("recursive schema not rejected as diagnostics: " ++ show rejectedSchema)
  generated <- either fail pure (generateCodecs "KyynFactCodec" (rootType checked))
  let entrySource = unlines ["module FactRoundTrip where", "import KyynFactCodec", "import Kyyn.Runtime.Json",
        "main :: IO ()", "main = do", "  input <- getContents",
        "  value <- either fail pure (parseValue input >>= decodeWith rootCodec)",
        "  output <- either fail pure (printValue (encodeWith rootCodec value))", "  putStrLn output"]
  roundTripSources <- either fail pure (guestSources (path "FactRoundTrip.hs")
    (sourceFiles sources ++ [(path "FactRoundTrip.hs", utf8 entrySource), (path "KyynFactCodec.hs", utf8 generated)]))
  compiled <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestCompilation toolchain $
    compileGuest roundTripSources
  entry <- either (fail . show) (either (fail . show) pure) compiled
  let input = "{\"todos\":[{\"id\":\"todo-001\",\"value\":{\"title\":\"A task\",\"owner\":\"todo-001\"}}],\"people\":[]}"
      invoke bytes = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestCompilation toolchain $
        executeCompiled entry bytes
  inputValue <- either fail pure (Aeson.eitherDecodeStrict input)
  code <- either fail pure (fileTree files)
  checkedInput <- either (fail . show) pure (runPureEff (runDhallHandling (runRootStore (checkRootValue rootContract inputValue))))
  root <- either (fail . show) pure (runPureEff (runDhallHandling (runRootStore (materializeRoot rootContract code checkedInput))))
  CheckedValue _ reloaded <- either (fail . show) pure (runPureEff (runDhallHandling (runRootStore (loadRootValueForChecking root))))
  (output, status) <- invoke (Lazy.toStrict (Aeson.encode reloaded)) >>= either (fail . show) pure
  let expectedValue = Aeson.eitherDecodeStrict input :: Either String Aeson.Value
  unless (status == ProcessExit 0 "" && Aeson.eitherDecodeStrict output == expectedValue)
    (fail ("FactId string/envelope round trip failed: " ++ show (output,status)))
  let wrapped = Text.encodeUtf8 (Text.replace "\"id\":\"todo-001\""
        "\"id\":{\"tag\":\"FactId\",\"value\":\"todo-001\"}" (Text.decodeUtf8 input))
  (_, ProcessExit rejected _) <- invoke wrapped >>= either (fail . show) pure
  unless (rejected /= 0) (fail "tagged SDK FactId accepted")
  putStrLn "Checked SDK Fact envelope round trip uses plain-string IDs and rejects tagged IDs."
  putStrLn "Named Haskell metadata evaluated through real MicroHs and fixed JSON codec."
  reportFiles <- mapM (\(base,file) -> (,) (path file) <$> Bytes.readFile (repo </> base </> file))
    [("shared/kyyn-types/src", "Kyyn/Types/Diagnostic.hs"),
     ("guest/kyyn-sdk/src", "Kyyn/Validation.hs"),
     ("guest/kyyn-runtime/src", "Kyyn/Runtime/Validation.hs")]
  let reportSource = unlines
        ["module ValidationEntry where", "import Kyyn.Validation", "import qualified Authored", "import Kyyn.Schema",
         "validate :: Authored.Root -> ValidationReport",
         "validate (Authored.Root todos _) = ValidationReport ([Diagnostic Warning \"uncertain\" \"München 🦋\" Nothing,",
         "  Diagnostic Warning \"fact\" \"Review name\" (Just (FactLocation \"todos\" \"todo-001\" (Just \"name\"))),",
         "  Diagnostic Warning \"source\" \"Check source\" (Just (SourceLocation \"Validate.hs\" 12 3)),",
         "  Diagnostic Warning \"example\" \"Illustrative\" (Just (ExampleLocation \"sample\"))] ++",
         "  if any (\\(Fact _ (Authored.Todo title _)) -> null title) todos then",
         "    [Diagnostic Error \"blank\" \"Name is blank\" (Just (FactLocation \"todos\" \"todo-001\" Nothing))] else [])"]
      manifest = "{ schemaType = \"Authored.Root\", schemaMetadata = \"Authored.schemaMetadata\", validator = \"ValidationEntry.validate\" , queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text } }"
  authoredBytes <- maybe (fail "Missing captured Authored.hs") pure (lookup (path "Authored.hs") files)
  validationCode <- either fail pure (fileTree
    [(path "src/Authored.hs", authoredBytes), (path "src/ValidationEntry.hs", utf8 reportSource), (path "kb.dhall", utf8 manifest)])
  sdk <- either fail pure (fileTree (reportFiles ++ filter ((/= path "Authored.hs") . fst) files))
  let emptySchema = "module Empty where\nimport Kyyn.Schema\ndata Root = Root deriving (Eq, Show)\nschemaMetadata :: SchemaMetadata\nschemaMetadata = SchemaMetadata [] [] []\n"
      emptyValidator = "module Validate where\nimport qualified Empty\nimport Kyyn.Validation\nvalidate :: Empty.Root -> ValidationReport\nvalidate _ = ValidationReport []\n"
      emptyManifest = Text.replace "ValidationEntry.validate" "Validate.validate"
        (Text.replace "Authored" "Empty" (Text.pack manifest))
  emptySource <- either fail pure (schemaSource
    ((path "Empty.hs", utf8 emptySchema) : filter ((/= path "Authored.hs") . fst) files)
    "Empty.Root" "Empty.schemaMetadata")
  emptyInspected <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
    . runGuestCompilation toolchain . runSchemaInspectionIO toolchain $ inspectSchema emptySource
  InspectedSchema emptyChecked _ <- either (fail . show) (either (fail . show) pure) emptyInspected
  emptyContract <- either (fail . show) pure (checkRootLayout emptyChecked)
  _ <- either fail pure (queryBindings emptyContract)
  emptyCode <- either fail pure (fileTree
    [(path "src/Empty.hs", utf8 emptySchema), (path "src/Validate.hs", utf8 emptyValidator),
     (path "kb.dhall", Text.encodeUtf8 emptyManifest)])
  emptyValue <- either (fail . show) pure
    (runPureEff (runDhallHandling (runRootStore (checkRootValue emptyContract (Aeson.object [])))))
  emptyRoot <- either (fail . show) pure
    (runPureEff (runDhallHandling (runRootStore (materializeRoot emptyContract emptyCode emptyValue))))
  emptyResponse <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestCompilation toolchain
    . runSchemaInspectionIO toolchain . runDhallHandling . runRootStore . runRootExecution sdk $ do
      prepared <- prepareRoot emptyRoot
      either (pure . Left) validateRoot prepared
  unless (emptyResponse == Right (Right (ValidationReport [])))
    (fail ("Empty root validation failed: " ++ show emptyResponse))
  putStrLn "Empty root: real schema metadata, zero-collection bindings, Dhall facts and guest validator passed."
  forM_ [(input, expectedWarnings),
         (Text.encodeUtf8 (Text.replace "A task" "" (Text.decodeUtf8 input)), expectedWarnings ++ [blankError])] $ \(inputBytes, expectedDiagnostics) -> do
    factValue <- either fail pure (Aeson.eitherDecodeStrict inputBytes)
    checkedFacts <- either (fail . show) pure (runPureEff (runDhallHandling (runRootStore (checkRootValue rootContract factValue))))
    validationRoot <- either (fail . show) pure (runPureEff (runDhallHandling (runRootStore (materializeRoot rootContract validationCode checkedFacts))))
    response <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestCompilation toolchain
      . runSchemaInspectionIO toolchain . runDhallHandling . runRootStore . runRootExecution sdk $ do
        prepared <- prepareRoot validationRoot
        either (pure . Left) validateRoot prepared
    report <- either (fail . show) (either (fail . show) pure) response
    unless (report == ValidationReport expectedDiagnostics)
      (fail ("RootExecution changed the report: " ++ show response))
  putStrLn "Real RootExecution reads captured facts, invokes the manifest validator, and preserves semantic errors and warnings."

expectedWarnings :: [Diagnostic]
expectedWarnings =
  [Diagnostic Warning "uncertain" "München 🦋" Nothing,
   Diagnostic Warning "fact" "Review name" (Just (FactLocation "todos" "todo-001" (Just "name"))),
   Diagnostic Warning "source" "Check source" (Just (SourceLocation "Validate.hs" 12 3)),
   Diagnostic Warning "example" "Illustrative" (Just (ExampleLocation "sample"))]

blankError :: Diagnostic
blankError = Diagnostic Error "blank" "Name is blank" (Just (FactLocation "todos" "todo-001" Nothing))

reportTests :: IO ()
reportTests = do
  let empty = ValidationReport []
      warnings = ValidationReport expectedWarnings
      errors = ValidationReport (expectedWarnings ++ [blankError])
  unless (decodeReport "[]" == Right empty && checkReport True empty == Passed True empty &&
      checkReport True warnings == Passed True warnings && checkReport True errors == Rejected errors)
    (fail "Report classification lost diagnostics or rejected warnings")
  forM_ ["null", "{}", "[{}]", "[] trailing", "[1]",
    "[{\"severity\":{\"tag\":\"Info\"},\"code\":\"c\",\"message\":\"m\",\"location\":{\"tag\":\"None\"}}]",
    "[{\"severity\":{\"tag\":\"Error\"},\"code\":\"c\",\"message\":\"m\",\"location\":null}]",
    "[{\"severity\":{\"tag\":\"Error\",\"value\":true},\"code\":\"c\",\"message\":\"m\",\"location\":{\"tag\":\"None\"}}]",
    "[{\"severity\":{\"tag\":\"Error\"},\"code\":\"c\",\"message\":\"m\",\"location\":{\"tag\":\"Some\",\"value\":{\"tag\":\"Source\",\"value\":{\"file\":\"x\",\"line\":1,\"column\":\"2\"}}}}]"] $ \source ->
      case decodeReport source of Left _ -> pure (); Right _ -> fail ("Malformed report accepted: " ++ show source)
  case decodeReport (Bytes.pack [255]) of Left _ -> pure (); Right _ -> fail "Invalid report UTF-8 accepted"
  putStrLn "Validation report decoding and warning/error classification passed."
