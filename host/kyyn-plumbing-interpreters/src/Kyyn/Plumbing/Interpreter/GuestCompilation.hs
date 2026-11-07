{-# LANGUAGE GADTs, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Plumbing.Interpreter.GuestCompilation (GuestBuildEnvironment(..), runGuestCompilation) where

import Control.Monad (forM_)
import Data.Aeson (eitherDecodeStrict', withObject, (.:), Value)
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Text.Encoding.Error (lenientDecode)
import Numeric (showHex)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Path
import Kyyn.Plumbing.Capability.FileSystem
import Kyyn.Plumbing.Capability.GuestCompilation
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process

-- The composition root resolves Nix and the execution platform once. The cache
-- owns normal Nix out-links, retaining outputs across describe/invoke calls.
data GuestBuildEnvironment = GuestBuildEnvironment
  { nixExecutable :: FilePath, targetSystem :: String
  , environment :: [(String,String)], cache :: DirectoryScope
  }

runGuestCompilation :: (FileSystem :> es, Process.ProcessExecution :> es)
  => GuestBuildEnvironment -> Eff (GuestCompilation : es) a -> Eff es a
runGuestCompilation settings = interpret $ \_ (CompileGuest sources) -> do
  let digest = sourceIdentity sources
      key = settings.targetSystem ++ "-" ++ concatMap hex (Bytes.unpack digest)
      retention = scopePath settings.cache ++ "/" ++ key
      receipt = checkedPath (key ++ ".json")
      program bytes = case eitherDecodeStrict' bytes >>= parseEither parseOutput of
        Left _ -> pure Nothing
        Right (derivation,output) -> case directoryScope output of
          Left _ -> pure Nothing
          Right outputScope -> do
            size <- fileSize outputScope (checkedPath "bin/kyyn-guest")
            retainedSize <- fileSize settings.cache (checkedPath (key ++ "/bin/kyyn-guest"))
            pure $ if size /= Nothing && retainedSize /= Nothing then Just (CompiledProgram
              (BuildIdentity digest settings.targetSystem derivation output)
              (scopedPath outputScope (checkedPath "bin/kyyn-guest")) retention)
              else Nothing
  saved <- readOptionalBytes settings.cache receipt
  cached <- maybe (pure Nothing) program saved
  case cached of
    Just compiled -> pure (Right compiled)
    Nothing -> withTemporaryScope $ \scope -> do
      forM_ (sourceFiles sources) $ \(path,bytes) -> writeBytes scope path bytes
      ensureDirectory settings.cache
      ignored <- readOptionalBytes settings.cache (checkedPath ".gitignore")
      case ignored of
        Nothing -> writeBytes settings.cache (checkedPath ".gitignore") "*\n"
        Just _ -> pure ()
      let installable = "path:" ++ scopePath scope ++ "#packages." ++ settings.targetSystem ++ ".kyyn-guest"
          -- --no-write-lock-file would allow an in-memory lock update.
          arguments = ["--extra-experimental-features","nix-command flakes","build",installable,
            "--no-update-lock-file","--json","--out-link",retention]
      (stdout,Process.ProcessExit status stderr) <- Process.withProcess
        (Process.ProcessSpec settings.nixExecutable arguments (scopePath scope) settings.environment) $ do
          Process.closeStdin
          output <- Process.collectStdout
          exit <- Process.awaitExit
          pure (output,exit)
      if status /= 0 then pure (problem "guest.build" ("Nix guest build failed:\n" ++ diagnosticText (stderr <> stdout)))
      else case eitherDecodeStrict' stdout >>= parseEither parseOutput of
        Left message -> pure (problem "guest.build-output" ("Invalid Nix build response: " ++ message))
        Right _ -> do
          built <- program stdout
          case built of
            Nothing -> pure (problem "guest.build-output" "Selected Nix output or retention link does not contain bin/kyyn-guest")
            Just compiled -> do
              replaceBytes settings.cache receipt stdout
              pure (Right compiled)
  where
    hex byte = let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits
    checkedPath = either error id . relativePath
    problem code message = Left [errorDiagnostic code message]
    diagnosticText = Text.unpack . Text.decodeUtf8With lenientDecode

parseOutput :: [Value] -> Parser (FilePath,FilePath)
parseOutput [value] = withObject "Nix build result" (\result -> do
  derivation <- result .: "drvPath"
  outputs <- result .: "outputs"
  output <- withObject "Nix outputs" (.: "out") outputs
  pure (derivation,output)) value
parseOutput _ = fail "Expected one Nix guest build output"
