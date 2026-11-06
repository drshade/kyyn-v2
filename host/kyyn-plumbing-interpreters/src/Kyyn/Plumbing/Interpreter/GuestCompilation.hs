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
runGuestCompilation settings = interpret $ \_ (CompileGuest sources) -> withTemporaryScope $ \scope -> do
  forM_ (sourceFiles sources) $ \(path,bytes) -> writeBytes scope path bytes
  ensureDirectory settings.cache
  ignored <- readOptionalBytes settings.cache (checkedPath ".gitignore")
  case ignored of
    Nothing -> writeBytes settings.cache (checkedPath ".gitignore") "*\n"
    Just _ -> pure ()
  let digest = sourceIdentity sources
      key = settings.targetSystem ++ "-" ++ concatMap hex (Bytes.unpack digest)
      retention = scopePath settings.cache ++ "/" ++ key
      installable = "path:" ++ scopePath scope ++ "#packages." ++ settings.targetSystem ++ ".kyyn-guest"
      -- Do not combine this with --no-write-lock-file: Nix then permits an
      -- in-memory regenerated lock, defeating --no-update-lock-file's refusal.
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
    Right (derivation,output) -> case directoryScope output of
      Left message -> pure (problem "guest.build-output" message)
      Right outputScope -> do
        let entry = checkedPath "bin/kyyn-guest"
        exists <- entryExists outputScope entry
        pure $ if exists then Right (CompiledProgram
          (BuildIdentity digest settings.targetSystem derivation output) (scopedPath outputScope entry) retention)
          else problem "guest.build-output" "Selected Nix output does not contain bin/kyyn-guest"
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
