{-# LANGUAGE OverloadedStrings, GADTs, LambdaCase, DataKinds #-}
module Main where

import Control.Monad (unless)
import qualified Data.ByteString as Bytes
import Data.IORef
import Effectful (liftIO, runEff, Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.CompiledProgram
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.GuestApi
import Kyyn.Domain.Path
import Kyyn.MicroHs.Interpreter.InspectionCache
import Kyyn.MicroHs.Interpreter.SchemaInspection
import Kyyn.MicroHs.Inspection (inspectionSettings)
import Kyyn.MicroHs.Toolchain
import Kyyn.Plumbing.Capability.SchemaInspection
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Protocol.Inspection
import Kyyn.Plumbing.Protocol.GuestApi
import System.Directory (createDirectory, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

type CacheEffects = '[DhallHandling,FileSystem,Failure,IOE]

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
      run :: Eff CacheEffects a -> IO (Either OperationalFailure a)
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
  metadataOnHit temporary
  putStrLn "Inspection cache roundtrips, hits, invalidation, disabled mode, refusals and corruption checks passed."

metadataOnHit :: FilePath -> IO ()
metadataOnHit temporary = do
  let path = either error id . relativePath
      scope = either error id . directoryScope
      compiler = scope (temporary </> "absent-compiler")
      cache = Just (InspectionCache "test" (scope (temporary </> "metadata-cache")))
      selected = either error id (schemaSource [(path "A.hs","captured fixture")] "A.Root" "A.metadata")
      sources = sourceFiles (schemaSources selected)
      run :: Eff CacheEffects a -> IO (Either OperationalFailure a)
      run action = runEff . runFailure . runFileSystemIO (scope temporary) . runDhallHandling $ action
      cached = cachedInspection cache "inspection" "A.Root" (inspectionSettings (scopePath compiler) "A.Root") sources
        encodeInspection decodeInspection
  seeded <- run (cached (pure (Right (StringType,[path "A.hs"]))))
  unless (seeded == Right (Right (StringType,[path "A.hs"]))) (fail "seed raw inspection")
  executions <- newIORef (0 :: Int)
  let check reply = run . metadataExecution executions reply . metadataCompiler
        . runSchemaInspectionIO (GuestToolchain compiler) cache $ inspectSchema selected
  valid <- check "{\"roles\":[],\"fieldRoles\":[],\"collections\":[]}"
  unless (case valid of Right (Right _) -> True; _ -> False) (fail (show valid))
  invalid <- check "{\"roles\":[],\"fieldRoles\":[{\"recordType\":\"Missing\",\"field\":\"missing\",\"role\":\"missing\"}],\"collections\":[]}"
  unless (case invalid of Right (Left (_:_)) -> True; _ -> False) (fail "cached structure bypassed contract checking")
  readIORef executions >>= \count -> unless (count == 2) (fail "metadata was not evaluated on each hit")

metadataCompiler :: Eff (GuestCompilation : es) a -> Eff es a
metadataCompiler = interpret $ \_ (CompileGuest _) -> pure (Right
  (CompiledProgram (BuildIdentity "fixture" "fixture") (either error id (relativePath "program.comb"),"fixture")))

metadataExecution :: IOE :> es => IORef Int -> Bytes.ByteString -> Eff (GuestExecution : es) a -> Eff es a
metadataExecution calls reply = interpret $ \_ -> \case
  ExecuteCompiled _ _ -> do
    liftIO (modifyIORef' calls (+1))
    pure (reply,ProcessExit 0 "")
  ExecuteGuest _ _ _ -> error "Metadata should use one-shot execution"
