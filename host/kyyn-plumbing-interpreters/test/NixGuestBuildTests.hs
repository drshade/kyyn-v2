-- Real Nix build from a captured, pre-locked KB: output retention, immutable
-- describe/invoke, unchanged lock, and refusal to repair an incomplete lock.
{-# LANGUAGE GHC2021, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Data.Aeson (object, (.=), encode, Value)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.Either (isLeft)
import Effectful (runEff)
import System.Environment (getArgs, getEnvironment)
import System.Directory (doesPathExist)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.Path
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Guest (checkedEntries)
import qualified Kyyn.Types.Guest as G
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution
import Kyyn.Plumbing.Capability.GuestInspection
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import Kyyn.Plumbing.Interpreter.GuestCompilation
import Kyyn.Plumbing.Interpreter.GuestExecution
import Kyyn.Plumbing.Interpreter.GuestInspection
import Kyyn.Plumbing.Interpreter.SchemaInspection
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.Plumbing.Interpreter.Failure

main :: IO ()
main = do
  arguments <- getArgs
  (fixture,nix) <- case arguments of
    [source,compiler] -> (,) <$> right (directoryScope source) <*> pure compiler
    _ -> fail "Expected LOCKED_FIXTURE_DIRECTORY NIX_EXECUTABLE"
  environment <- getEnvironment
  originalLock <- Bytes.readFile (scopePath fixture ++ "/flake.lock")
  withSystemTempDirectory "kyyn-host-nix-build" $ \directory -> do
    scope <- right (directoryScope directory)
    cache <- right (directoryScope (directory ++ "/retained"))
    captured <- runEff . runFailure . runFileSystemIO scope $ FileSystem.readTree fixture
    tree <- right captured
    sources <- right (guestSources RootEntries (files tree))
    let settings = GuestBuildEnvironment nix "x86_64-linux" environment cache
        run action = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
          . runGuestExecution environment . runGuestInspection . runGuestCompilation settings . runSchemaInspection $ action
    result <- run $ runExceptT $ do
      program <- ExceptT (compileGuest sources)
      description <- ExceptT (describeGuest program)
      pure (program,description)
    (program,description) <- right result >>= right
    unless (map G.entryName (checkedEntries description) == ["validate","total"]) (fail "Wrong built entries")
    unless (program.identity.sourcesDigest == sourceIdentity sources) (fail "Capture identity changed")
    retained <- doesPathExist program.retentionRoot
    unless retained (fail "Nix output is not retained")
    -- The compilation scope has already been removed; invocation uses its store output.
    invoked <- run (executeCompiledEntry "validate" program (Lazy.toStrict (encode (object
      ["operation" .= ("invoke" :: String),"entry" .= ("validate" :: String),
       "argument" .= object ["items" .= ([] :: [Value])]]))))
    response <- right invoked
    unless (response == "[]") (fail "Built guest validation failed")
    unchanged <- Bytes.readFile (scopePath fixture ++ "/flake.lock")
    unless (unchanged == originalLock) (fail "Host changed the authored lock")
    schemaSelection <- right (Schema.schemaSource [(p,if relativeName p == "src/Queries.hs"
      then "module Queries where\nunfinished =\n" else bytes) | (p,bytes) <- files tree])
    schema <- run (Schema.inspectSchema schemaSelection) >>= right >>= right
    unless (map relativeName schema.loadedSources == ["src/Main.hs"])
      (fail "Host schema inspection included metadata-only or unfinished sources")
    incomplete <- right (guestSources RootEntries [(p,if relativeName p == "flake.lock"
      then "{\"version\":7,\"root\":\"root\",\"nodes\":{\"root\":{}}}" else bytes) | (p,bytes) <- files tree])
    rejected <- run (compileGuest incomplete) >>= right
    unless (isLeft rejected) (fail "Host repaired an incomplete lock")
  putStrLn "Real host Nix build, retention, describe/invoke and frozen-lock checks passed."

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
