-- Native host boundaries: capture excludes runtime material and keys builds by
-- source/lock/selection; the actual process interpreter describes and invokes a
-- retained Nix executable without resolving or compiling another program.
{-# LANGUAGE GHC2021, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (object, (.=), encode, eitherDecodeStrict', Value(..))
import qualified Data.ByteString.Lazy as Lazy
import Data.Either (isLeft)
import Effectful (runEff)
import System.Environment (getArgs)
import System.Directory (canonicalizePath)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.Path
import Kyyn.Domain.Guest (checkedEntries)
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution
import Kyyn.Plumbing.Capability.GuestInspection
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Interpreter.GuestExecution
import Kyyn.Plumbing.Interpreter.GuestInspection
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.Plumbing.Interpreter.Failure

main :: IO ()
main = do
  let path = either error id . relativePath
      code = [(path "flake.nix","{}"),(path "flake.lock","{}"),(path "src/Main.hs","module Main where")]
      material = [(path "facts/items/a.dhall","private fact"),(path ".kyyn/secrets/graph.dhall","private token"),
        (path ".git/config","private configuration"),(path ".env","private environment"),
        (path "dist-newstyle/cache/plan.json","cache"),(path "recipes/state.dhall","private state")]
  captured <- right (guestSources RootEntries (code ++ material))
  baseline <- right (guestSources RootEntries code)
  unless (sourceIdentity captured == sourceIdentity baseline) (fail "Runtime material affected source identity")
  unless (all ((`notElem` map fst material) . fst) (sourceFiles captured)) (fail "Private runtime material captured")
  discovery <- right (guestSources (DiscoveryEntries RootSchema) code)
  unless (sourceIdentity discovery /= sourceIdentity baseline) (fail "Build selection absent from identity")
  changed <- right (guestSources RootEntries [(p,if p == path "flake.lock" then "{\"changed\":true}" else bytes) | (p,bytes) <- code])
  unless (sourceIdentity changed /= sourceIdentity baseline) (fail "Lock absent from source identity")
  unless (isLeft (guestSources RootEntries [(path "flake.nix","{}")])) (fail "Missing lock accepted")
  unless (isLeft (guestSources RootEntries ((path ".kyyn-build.json","{}") : code))) (fail "Authored build selection accepted")
  arguments <- getArgs
  executable <- case arguments of
    [selected] -> canonicalizePath selected
    _ -> fail "Expected a Nix-built guest executable"
  let output = takeDirectory (takeDirectory executable)
      program = CompiledProgram (BuildIdentity (sourceIdentity baseline) "x86_64-linux" "test.drv" output) executable ".build/nix-guest"
  withSystemTempDirectory "kyyn-native-host" $ \directory -> do
    scope <- right (directoryScope directory)
    result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection $ do
        description <- describeGuest program
        invocation <- executeCompiled program (Lazy.toStrict (encode (object
          ["operation" .= ("invoke" :: String),"entry" .= ("validate" :: String),
           "argument" .= object ["items" .= ([] :: [Value])]])))
        pure (description,invocation)
    (description,(response,ProcessExit status errors)) <- right result
    checked <- right description
    unless (map G.entryName (checkedEntries checked) == ["validate","total"]) (fail "Wrong checked native entries")
    unless (status == 0) (fail (show errors))
    value <- right (eitherDecodeStrict' response :: Either String Value)
    unless (value == Array mempty) (fail "Native validator invocation failed")
  putStrLn "Native host source capture, description and invocation checks passed."

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
