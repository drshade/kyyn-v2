-- Retained guest reuse across interpreter instances, exact input/platform keys,
-- cache removal/corruption and failed-build retry. A local Nix stand-in counts
-- process launches; nix-guest-build separately verifies real store retention.
{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.Either (isLeft)
import Effectful (runEff)
import System.Directory (createDirectoryIfMissing, setPermissions, getPermissions, removeFile)
import qualified System.Directory as Directory
import System.Environment (getEnvironment)
import System.FilePath (takeFileName)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.Path
import Kyyn.Plumbing.Capability.GuestCompilation hiding (executable, targetSystem)
import Kyyn.Plumbing.Interpreter.GuestCompilation
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.Plumbing.Interpreter.Failure

main :: IO ()
main = withSystemTempDirectory "kyyn-compile-cache" $ \directory -> do
  scope <- right (directoryScope directory)
  cache <- right (directoryScope (directory ++ "/cache"))
  environment <- getEnvironment
  let output = directory ++ "/output"
      stub = directory ++ "/nix"
      calls = directory ++ "/calls"
      response = directory ++ "/response.json"
  createDirectoryIfMissing True (output ++ "/bin")
  writeFile calls ""
  Lazy.writeFile response (encode [object ["drvPath" .= (directory ++ "/guest.drv"), "outputs" .= object ["out" .= output]]])
  writeFile stub $ unlines
    [ "#!/bin/sh", "set -eu", "echo call >> \"$KYYN_TEST_CALLS\""
    , "if [ \"${KYYN_TEST_FAIL:-0}\" = 1 ]; then exit 1; fi"
    , "while [ \"$#\" -gt 0 ]; do"
    , "  if [ \"$1\" = --out-link ]; then shift; retention=$1; fi; shift"
    , "done"
    , "echo executable > \"$KYYN_TEST_OUTPUT/bin/kyyn-guest\""
    , "ln -sfn \"$KYYN_TEST_OUTPUT\" \"$retention\""
    , "cat \"$KYYN_TEST_RESPONSE\""
    ]
  permissions <- getPermissions stub
  setPermissions stub permissions { Directory.executable = True }
  let settings = GuestBuildEnvironment stub "test-system"
        ([ ("KYYN_TEST_CALLS",calls), ("KYYN_TEST_OUTPUT",output), ("KYYN_TEST_RESPONSE",response)] ++ environment) cache
      build config sources = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
        . runGuestCompilation config $ compileGuest sources
      expectCalls count = do
        actual <- length . lines <$> readFile calls
        unless (actual == count) (fail ("Expected " ++ show count ++ " builds, got " ++ show actual))
      source selection content = right (guestSources selection
        [(path "flake.nix","locked flake"), (path "flake.lock","locked inputs"), (path "src/Main.hs",content)])
  base <- source RootEntries "original"
  first <- build settings base >>= right >>= right
  second <- build settings base >>= right >>= right
  unless (first == second) (fail "Cache reuse changed build identity")
  expectCalls 1
  changed <- source RootEntries "changed"
  _ <- build settings changed >>= right >>= right
  selected <- source (DiscoveryEntries RootSchema) "original"
  _ <- build settings selected >>= right >>= right
  _ <- build (GuestBuildEnvironment stub "other-system" settings.environment cache) base >>= right >>= right
  expectCalls 4
  let changedFile name = right (guestSources RootEntries
        [(p,if relativeName p == name then bytes <> " changed" else bytes)
        | (p,bytes) <- sourceFiles base, relativeName p /= ".kyyn-build.json"])
  mapM_ (\name -> changedFile name >>= build settings >>= right >>= right >> pure ()) ["flake.nix","flake.lock"]
  expectCalls 6
  let receipt = scopePath cache ++ "/" ++ takeFileName first.retentionRoot ++ ".json"
  Bytes.writeFile receipt "invalid receipt"
  _ <- build settings base >>= right >>= right
  expectCalls 7
  removeFile receipt
  _ <- build settings base >>= right >>= right
  expectCalls 8
  removeFile first.retentionRoot
  _ <- build settings base >>= right >>= right
  expectCalls 9
  removeFile (output ++ "/bin/kyyn-guest")
  _ <- build settings base >>= right >>= right
  expectCalls 10
  fresh <- source RootEntries "failure retry"
  rejected <- build settings { environment = ("KYYN_TEST_FAIL","1") : settings.environment } fresh >>= right
  unless (isLeft rejected) (fail "Failed build succeeded")
  _ <- build settings fresh >>= right >>= right
  expectCalls 12
  putStrLn "Guest cache reuse, invalidation, retention recovery and retry checks passed."
  where
    path = either error id . relativePath

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
