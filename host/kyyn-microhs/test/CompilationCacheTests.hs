-- Recording compiler plus real filesystem: artifact reuse, changed-input misses,
-- empty-entry repair, disabled cache and storage failures; no MicroHs compilation.

{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module Main where

import Control.Monad (unless)
import qualified Data.ByteString as Bytes
import Data.IORef
import Data.List (isSuffixOf)
import Effectful (Eff, IOE, (:>), liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import Kyyn.Domain.Failure
import Kyyn.Domain.Path
import Kyyn.MicroHs.Interpreter.GuestCompilation
import Kyyn.MicroHs.Toolchain
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.ProcessExecution
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem
import System.Directory
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = withSystemTempDirectory "kyyn-compile-cache" $ \temporary -> do
  let path = either error id . relativePath
      scope = either error id . directoryScope
      work = temporary </> "work"
      cachePath = temporary </> "cache"
      cache = scope cachePath
      toolchain = GuestToolchain (scope (temporary </> "toolchain"))
      sources value = either error id (guestSources (path "Main.hs") [(path "Main.hs", value)])
      original = sources "first captured input"
      assert label passed = unless passed (fail label)
  createDirectory work
  calls <- newIORef (0 :: Int)
  let compile selected cacheDirectory status input = runEff . runFailure . fakeCompiler calls status . runFileSystemIO (scope work)
        . runGuestCompilation selected cacheDirectory $ compileGuest input
      cached = compile toolchain (Just cache) 0
  first <- cached original
  assert "compiled successfully" (case first of Right (Right _) -> True; _ -> False)
  second <- cached original
  assert "hit returns identical identity and bytes" (first == second)
  readIORef calls >>= assert "hit skips compiler" . (== 1)
  cached (sources "changed captured input") >>= \changed -> assert "changed source identity" (changed /= first)
  readIORef calls >>= assert "changed source misses" . (== 2)
  entries <- filter (isSuffixOf ".comb") <$> listDirectory cachePath
  mapM_ (\name -> Bytes.writeFile (cachePath </> name) Bytes.empty) entries
  rebuilt <- cached original
  assert "empty entry rebuilt identically" (rebuilt == first)
  readIORef calls >>= assert "empty entry invokes compiler" . (== 3)
  _ <- compile (GuestToolchain (scope (temporary </> "other-toolchain"))) (Just cache) 0 original
  readIORef calls >>= assert "toolchain location participates in key" . (== 4)
  _ <- compile toolchain Nothing 0 original
  _ <- compile toolchain Nothing 0 original
  readIORef calls >>= assert "uncached compilation always invokes compiler" . (== 6)
  let invalid = sources "rejected input"
  rejected <- compile toolchain (Just cache) 1 invalid
  assert "compiler refusal retained" (case rejected of Right (Left _) -> True; _ -> False)
  _ <- compile toolchain (Just cache) 1 invalid
  readIORef calls >>= assert "rejections never cached" . (== 8)
  current <- filter (isSuffixOf ".comb") <$> listDirectory cachePath
  mapM_ (\name -> Bytes.writeFile (cachePath </> name) "corrupt but nonempty") current
  trusted <- cached original
  assert "nonempty bytes are trusted, not silently regenerated" (case trusted of
    Right (Right (CompiledProgram _ (_,bytes))) -> bytes == "corrupt but nonempty"
    _ -> False)
  readIORef calls >>= assert "trusted hit skips compiler" . (== 8)
  mapM_ (\name -> removeFile (cachePath </> name) >> createDirectory (cachePath </> name)) current
  unreadable <- cached original
  assert "unreadable entry is storage failure" (case unreadable of Left (StorageUnavailable _) -> True; _ -> False)
  remaining <- listDirectory work
  assert "no temporary source trees remain" (null remaining)
  putStrLn "Compile cache hits, source/toolchain misses, uncached calls, empty repair, refusals and storage faults passed."

fakeCompiler :: IOE :> es => IORef Int -> Int -> Eff (ProcessExecution : es) a -> Eff es a
fakeCompiler calls status = interpret $ \env (WithProcess (ProcessSpec _ _ directory _) action) -> do
  liftIO (modifyIORef' calls (+ 1))
  if status == 0 then liftIO (Bytes.writeFile (directory </> "program.comb") "compiled fixture") else pure ()
  localSeqUnlift env $ \unlift -> unlift $ interpret (\_ -> \case
    WriteStdin _ -> pure ()
    CloseStdin -> pure ()
    ReadStdout -> pure Nothing
    AwaitExit -> pure (ProcessExit status "fixture compiler refusal")) action
