{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Monad (unless)
import qualified Data.ByteString as Bytes
import Data.IORef
import Effectful (liftIO, runEff)
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.GuestApi
import Kyyn.Domain.Path
import Kyyn.MicroHs.Interpreter.InspectionCache
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Protocol.Inspection
import Kyyn.Plumbing.Protocol.GuestApi
import System.Directory (createDirectory, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = withSystemTempDirectory "kyyn-inspection-cache" $ \temporary -> do
  let path = either error id . relativePath
      scope = either error id . directoryScope
      directory = scope (temporary </> "cache")
      sources = [(path "A.hs","module A where"),(path "B.hs","module B where")]
      structure = Algebraic "A.Root" [StringType]
        [Constructor "A.Root" [(Just "items",ListType (OptionalType IntegerType)),(Just "name",StringType)]]
      value = (structure,[path "A.hs",path "B.hs"])
      assert label success = unless success (fail label)
      run action = runEff . runFailure . runFileSystemIO (scope temporary) . runDhallHandling $ action
  calls <- newIORef (0 :: Int)
  let inspect selectedCache settings input outcome = run $ cachedInspection selectedCache "inspection" "A.Root" settings input
        encodeInspection decodeInspection (liftIO (modifyIORef' calls (+1)) >> pure outcome)
      cache = Just (InspectionCache "revision-one" directory)
      cached = inspect cache "A.Root flags"
      key = scopedPath directory (inspectionKey "revision-one" (show ("inspection" :: String,"A.Root flags" :: String)) sources)
  first <- cached sources (Right value)
  assert "raw type and relative closure roundtrip" (first == Right (Right value))
  second <- cached (reverse sources) (Left [])
  assert "hit identical despite capture order" (second == first)
  readIORef calls >>= assert "inspection skipped on hit" . (==1)
  _ <- inspect cache "B.Root flags" sources (Right value)
  _ <- inspect cache "A.Root other flags" sources (Right value)
  _ <- inspect (Just (InspectionCache "revision-two" directory)) "A.Root flags" sources (Right value)
  _ <- cached [(path "A.hs","changed")] (Right value)
  _ <- cached [(path "C.hs","module A where"),(path "B.hs","module B where")] (Right value)
  readIORef calls >>= assert "selection, settings, revision, bytes and paths invalidate" . (==6)
  _ <- inspect Nothing "A.Root flags" sources (Right value)
  _ <- inspect Nothing "A.Root flags" sources (Right value)
  readIORef calls >>= assert "unidentified builds do not cache" . (==8)
  let rejected = Left [errorDiagnostic "fixture" "rejected"]
  _ <- inspect cache "rejected" sources rejected
  _ <- inspect cache "rejected" sources rejected
  readIORef calls >>= assert "compiler failures not cached" . (==10)
  Bytes.writeFile key Bytes.empty
  _ <- cached sources (Right value)
  readIORef calls >>= assert "empty entry repaired" . (==11)
  Bytes.writeFile key "broken Dhall"
  broken <- cached sources (Right value)
  assert "malformed cache diagnosed" (case broken of Right (Left (_:_)) -> True; _ -> False)
  readIORef calls >>= assert "malformed entry does not silently rerun" . (==11)
  removeFile key
  createDirectory key
  unreadable <- cached sources (Right value)
  assert "unreadable entry propagates operational failure" (case unreadable of Left _ -> True; _ -> False)
  let api = [ApiModule "A" [ApiSymbol "value" ValueNamespace "A.value" "String" (Just "value :: String") (Just "Helpful documentation")]]
      apiInspect outcome = run $ cachedInspection cache "api-inspection" "A" "A.Root flags" sources
        encodeCatalogue decodeCatalogue (pure outcome)
  apiFirst <- apiInspect (Right api)
  apiSecond <- apiInspect (Left [])
  assert "API namespace separate, declarations and docs preserved" (apiFirst == Right (Right api) && apiSecond == apiFirst)
  putStrLn "Inspection cache roundtrips, hits, invalidation, disabled mode, refusals and corruption checks passed."
