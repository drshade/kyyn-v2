-- Native host boundaries: capture excludes runtime material and keys builds by
-- source/lock/selection; the actual process interpreter describes and invokes a
-- retained Nix executable without resolving or compiling another program.
{-# LANGUAGE GHC2021, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Data.Aeson (object, (.=), eitherDecodeStrict', Value(..))
import Data.Either (isLeft)
import Effectful (runEff)
import System.Environment (getArgs)
import System.Directory (canonicalizePath)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Plumbing.Protocol.EvolutionSources (captureEvolutionSources)
import Kyyn.Domain.Path
import Kyyn.Domain.Guest (checkedEntries)
import Kyyn.Domain.CompiledEntry (compiledEntries, entryProgram, entryDescription)
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution
import Kyyn.Plumbing.Capability.GuestInspection
import Kyyn.Plumbing.Interpreter.GuestExecution
import Kyyn.Plumbing.Interpreter.GuestInspection
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.Plumbing.Interpreter.Failure

main :: IO ()
main = do
  let path = either error id . relativePath
      code = [(path "flake.nix","{}"),(path "flake.lock","{}"),(path "src/Main.hs","module Main where")]
      material = [(path "views/report/index.html","page"),(path "views/report/style.css","styles"),(path "facts/items/a.dhall","private fact"),(path ".kyyn/secrets/graph.dhall","private token"),
        (path ".git/config","private configuration"),(path ".env","private environment"),
        (path "dist-newstyle/cache/plan.json","cache"),(path "recipes/state.dhall","private state")]
  captured <- right (guestSources RootEntries (code ++ material))
  baseline <- right (guestSources RootEntries code)
  unless (sourceIdentity captured == sourceIdentity baseline) (fail "Runtime material affected source identity")
  unless (all ((`notElem` map fst material) . fst) (sourceFiles captured)) (fail "Private runtime material captured")
  recipes <- right (guestSources (RecipeEntries [ClosedFlow "Flows.review",OpenState "State.State",ClosedFlow "Flows.review"]) code)
  reordered <- right (guestSources (RecipeEntries [OpenState "State.State",ClosedFlow "Flows.review"]) (code ++ material))
  unless (sourceIdentity recipes == sourceIdentity reordered && selectedBuild recipes == selectedBuild reordered)
    (fail "Recipe build selection depends on fact order or duplicates")
  target <- right (fileTree code)
  change <- right (fileTree [(path "Evolution.hs","module Evolution where")])
  migration <- right (captureEvolutionSources (EvolutionSelection [] Nothing Nothing) target change)
  unless (lookup (path "flake.lock") (sourceFiles migration) == Just "{}"
      && lookup (path ".kyyn-change/Evolution.hs") (sourceFiles migration) == Just "module Evolution where")
    (fail "Evolution lost target environment or change source separation")
  conflicting <- right (fileTree ((path ".kyyn-change/Shadow.hs","shadow") : code))
  unless (isLeft (captureEvolutionSources (EvolutionSelection [] Nothing Nothing) conflicting change))
    (fail "Target overwrote private change source")
  discovery <- right (guestSources (DiscoveryEntries RootSchema) code)
  unless (sourceIdentity discovery /= sourceIdentity baseline) (fail "Build selection absent from identity")
  changed <- right (guestSources RootEntries [(p,if p == path "flake.lock" then "{\"changed\":true}" else bytes) | (p,bytes) <- code])
  unless (sourceIdentity changed /= sourceIdentity baseline) (fail "Lock absent from source identity")
  unless (isLeft (guestSources RootEntries [(path "flake.nix","{}")])) (fail "Missing lock accepted")
  unless (isLeft (guestSources RootEntries ((path ".kyyn-build.json","{}") : code))) (fail "Authored build selection accepted")
  arguments <- getArgs
  (executable,schemaExecutable) <- case arguments of
    [selected] -> (,) <$> canonicalizePath selected <*> pure Nothing
    [selected,schema] -> (,) <$> canonicalizePath selected <*> (Just <$> canonicalizePath schema)
    _ -> fail "Expected a Nix-built guest executable and optional schema-only executable"
  let output = takeDirectory (takeDirectory executable)
      program = CompiledProgram (BuildIdentity (sourceIdentity baseline) "x86_64-linux" "test.drv" output) executable ".build/nix-guest"
  withSystemTempDirectory "kyyn-native-host" $ \directory -> do
    scope <- right (directoryScope directory)
    let run action = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
          . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection $ action
    checked <- run (describeGuest program) >>= right >>= right
    unless (map G.entryName (checkedEntries checked) == ["validate","total"]) (fail "Wrong checked native entries")
    validator <- case [entry | entry <- compiledEntries program checked,
      G.ValidatorEntry{} <- [entryDescription entry]] of
      [entry] -> pure entry
      _ -> fail "No checked validator entry"
    unless (entryProgram validator == program) (fail "Entry selection changed the immutable program")
    response <- run (executeEntry validator (object ["items" .= ([] :: [Value])])) >>= right
    value <- right (eitherDecodeStrict' response :: Either String Value)
    unless (value == Array mempty) (fail "Native validator invocation failed")
    forM_ schemaExecutable $ \selected -> do
      let schemaOutput = takeDirectory (takeDirectory selected)
          schemaProgram = CompiledProgram (BuildIdentity (sourceIdentity discovery) "x86_64-linux" "schema.drv" schemaOutput)
            selected ".build/discovery-guests-3"
      schema <- run (describeGuest schemaProgram) >>= right >>= right
      unless (null (compiledEntries schemaProgram schema)) (fail "Description-only entry acquired an invocation handle")
  putStrLn "Native host source capture, description and invocation checks passed."

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
