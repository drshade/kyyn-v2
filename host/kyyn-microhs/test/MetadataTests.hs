{-# LANGUAGE DataKinds, OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runEff)
import Kyyn.Types.SchemaMetadata
import Kyyn.Domain.Path
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.SchemaInspection.Metadata
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
  putStrLn "Named Haskell metadata evaluated through real MicroHs and fixed JSON codec."
