{-# LANGUAGE DataKinds, OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import qualified Data.ByteString as Bytes
import qualified Data.Aeson as Aeson
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runEff)
import Kyyn.Types.SchemaMetadata
import Kyyn.Domain.Path
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.SchemaInspection.Metadata
import Kyyn.Domain.Contract (checkContract, rootType)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)
import Kyyn.Plumbing.Capability.ProcessExecution
import Kyyn.MicroHs.Inspection (inspectDataType)
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

integration :: IO ()
integration = withSystemTempDirectory "kyyn-metadata" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  scope <- either fail pure (directoryScope temporary)
  toolchain <- GuestToolchain <$> either fail pure (directoryScope (repo </> "vendor/MicroHs"))
  let path = either error id . relativePath
      utf8 = Text.encodeUtf8 . Text.pack
  files <- mapM (\(base, file) -> (,) (path file) <$> Bytes.readFile (repo </> base </> file))
    [("host/kyyn-microhs/test/metadata", "Authored.hs"),
     ("shared/kyyn-types/src", "Kyyn/Types/SchemaMetadata.hs"),
     ("shared/kyyn-types/src", "Kyyn/Types/Fact.hs"),
     ("guest/kyyn-runtime/src", "Kyyn/Runtime/SchemaMetadata.hs"),
     ("guest/kyyn-runtime/src", "Kyyn/Runtime/Json.hs"),
     ("vendor/json", "Text/JSON/Types.hs"), ("vendor/json", "Text/JSON/String.hs")]
  adapter <- either fail pure (metadataAdapter "Authored.schemaMetadata")
  sources <- either fail pure (guestSources (path "KyynMetadataEntry.hs")
    ((path "KyynMetadataEntry.hs", utf8 adapter) : files))
  result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestCompilation toolchain $
    evaluateMetadata sources
  let expected = SchemaMetadata
        [RoleDecl "task-name" "Tasks in München 🦋" Title,
         RoleDecl "date" "When" Timeline, RoleDecl "status" "State" Badge]
        [FieldRole "Authored.Todo" "title" "task-name"]
        [CollectionDecl n n [("owner", "people")] | n <- ["todos", "people"]]
  unless (result == Right (Right expected)) (fail (show result))
  inspected <- inspectDataType (repo </> "vendor/MicroHs")
    [repo </> "host/kyyn-microhs/test/metadata", repo </> "shared/kyyn-types/src"] "Authored.Root"
    >>= either (fail . show) pure
  evaluated <- either (fail . show) (either (fail . show) pure) result
  checked <- either (fail . show) pure (checkContract inspected evaluated)
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
      invoke bytes = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope $
        withCompiledEntry entry $ do
          writeStdin bytes
          closeStdin
          output <- collectStdout
          status <- awaitExit
          pure (output, status)
  (output, status) <- invoke input >>= either (fail . show) pure
  let expectedValue = Aeson.eitherDecodeStrict input :: Either String Aeson.Value
  unless (status == ProcessExit 0 "" && Aeson.eitherDecodeStrict output == expectedValue)
    (fail ("FactId string/envelope round trip failed: " ++ show (output,status)))
  let wrapped = Text.encodeUtf8 (Text.replace "\"id\":\"todo-001\""
        "\"id\":{\"tag\":\"FactId\",\"value\":\"todo-001\"}" (Text.decodeUtf8 input))
  (_, ProcessExit rejected _) <- invoke wrapped >>= either (fail . show) pure
  unless (rejected /= 0) (fail "tagged SDK FactId accepted")
  putStrLn "Checked SDK Fact envelope round trip uses plain-string IDs and rejects tagged IDs."
  putStrLn "Named Haskell metadata evaluated through real MicroHs and fixed JSON codec."
