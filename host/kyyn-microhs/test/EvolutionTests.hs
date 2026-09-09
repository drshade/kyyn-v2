{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runEff, runPureEff)
import Kyyn.Domain.EvolutionReport
import Kyyn.Types.Evolution
import Kyyn.Types.Diagnostic
import Kyyn.Porcelain.Capability.EvolutionReport
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Path
import Kyyn.Types.SchemaMetadata
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, identityEvolutionSource, decodeEvolutionReply)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.ProcessExecution
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.MicroHs.Toolchain
import Kyyn.MicroHs.Interpreter.GuestCompilation
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, getEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode, CreateProcess(..))

main :: IO ()
main = do
  before <- checked "SchemaV1" [(Just "title",StringType)] "Title"
  renamed <- checked "SchemaV1" [(Just "title",StringType)] "New label"
  after <- checked "SchemaV2" [(Just "title",StringType),(Just "done",BoolType)] "Title"
  bindings <- right (evolutionBindings [("beforeRoot",before),("renamedRoot",renamed),("afterRoot",after)])
  forM_ [[],[("same",before),("same",after)],[("bad;name",before)]] $ \declarations ->
    case evolutionBindings declarations of Left _ -> pure (); Right _ -> fail "Invalid binding declarations accepted"
  let fingerprints = [contractFingerprint (contractId (rootSchema contract)) | contract <- [before,renamed,after]]
      source = Bytes.concat (map snd (files bindings))
  unless (all (\fingerprint -> Text.encodeUtf8 (Text.pack fingerprint) `Bytes.isInfixOf` source) fingerprints)
    (fail "Generated bindings lost their whole contract identities")
  getArgs >>= \args -> case args of
    ["--pure"] -> pure ()
    [] -> integration before renamed after bindings
    _ -> fail "usage: evolutions [--pure]"

checked :: String -> [(Maybe String,DataType)] -> String -> IO RootContract
checked moduleName fields label = right $ checkContract root metadata >>= checkRootLayout
  where
    todo = Algebraic (moduleName ++ ".Todo") [] [Constructor (moduleName ++ ".Todo") fields]
    fact = Algebraic "Kyyn.Types.Fact.Fact" [todo]
      [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,sdkFactIdType),(Nothing,todo)]]
    root = Algebraic (moduleName ++ ".Root") [] [Constructor (moduleName ++ ".Root") [(Just "todos",ListType fact)]]
    metadata = SchemaMetadata [RoleDecl "title" label Title] [] [CollectionDecl "todos" "todos" []]

integration :: RootContract -> RootContract -> RootContract -> FileTree -> IO ()
integration before renamed after bindings = withSystemTempDirectory "kyyn-evolution-proof" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  scope <- right (directoryScope temporary)
  toolchain <- GuestToolchain <$> right (directoryScope (repo </> "vendor/MicroHs"))
  let path = either error id . relativePath
      load base name = (,) (path name) <$> Bytes.readFile (repo </> base </> name)
  authored <- mapM (load "host/kyyn-microhs/test/evolution") ["SchemaV1.hs","SchemaV2.hs","Evolution.hs","Proof.hs"]
  support <- sequence
    ([load "shared/kyyn-types/src" ("Kyyn/Types/" ++ name ++ ".hs") | name <- ["Fact","Diagnostic","Evidence","Evolution","Program"]] ++
     [load "guest/kyyn-sdk/src" name | name <- ["Kyyn/Evolution.hs","Kyyn/Evolution/Internal.hs"]] ++
     [load "guest/kyyn-sdk/test" "EvolutionCore.hs"] ++
     [load "guest/kyyn-runtime/src" ("Kyyn/Runtime/" ++ name ++ ".hs") | name <- ["Json","Evolution","Validation"]] ++
     [load "vendor/json" name | name <- ["Text/JSON/Types.hs","Text/JSON/String.hs"]])
  let identitySource = Text.encodeUtf8 (Text.replace "module Evolution where" "module Identity where" (Text.decodeUtf8 identityEvolutionSource))
      captured = (path "Identity.hs",identitySource) : authored ++ support ++ files bindings
      compileGuestFiles entries = do
        sources <- right (guestSources (path "Proof.hs") entries)
        runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestCompilation toolchain $ compileGuest sources
      native label entries = do
        let directory = temporary </> label
        forM_ entries $ \(relative,bytes) -> do
          let target = directory </> relativeName relative
          createDirectoryIfMissing True (takeDirectory target)
          Bytes.writeFile target bytes
        readCreateProcessWithExitCode ((proc "ghc"
          ["-v0","-i","-i.","-outputdir","build","-main-is","Proof.main","Proof.hs","-o","proof"]){cwd=Just directory}) ""
  (nativeStatus,_,nativeError) <- native "native" captured
  unless (nativeStatus == ExitSuccess) (fail nativeError)
  (status,expected,errors) <- readCreateProcessWithExitCode (proc (temporary </> "native/proof") []) ""
  unless (status == ExitSuccess) (fail errors)
  compiled <- compileGuestFiles captured >>= right >>= right
  guest <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestCompilation toolchain $
    executeCompiled compiled Bytes.empty
  actual <- right guest
  unless (actual == (Text.encodeUtf8 (Text.pack expected),ProcessExit 0 "")) (fail ("GHC/MicroHs evolution proof differed: " ++ show actual))
  replies <- traverse (right . decodeEvolutionReply . Text.encodeUtf8 . Text.pack)
    [line | line <- lines expected, take 1 line == "{"]
  case replies of
    [Right observation@(EvolutionObservation _ (StepObservation _ (ObservedRoot _ input) _ : _)), Left refusal] -> do
      (_,EvolutionReport reports) <- right (runPureEff . runDhallHandling . runRootStore $
        checkEvolutionReport [renamed] before input after observation)
      unless (length reports == 3 && all (\(StepReport _ changes) -> length changes == 1) reports)
        (fail "Guest observations did not derive the three real fact changes")
      unless (refusal == EvolutionFailure [Diagnostic Error "evolution.refused" "Cannot reconcile λ"
        (Just (FactLocation "todos" "todo-001" (Just "title")))]) (fail "Guest refusal lost its structured diagnostic")
    _ -> fail "Expected successful guest observations and a separate refusal"
  let badType = [(p,if relativeName p == "Evolution.hs"
        then Text.encodeUtf8 (Text.replace "evolve beforeRoot beforeRoot" "evolve afterRoot beforeRoot" (Text.decodeUtf8 b)) else b) | (p,b) <- captured]
      badConstructor = [(p,if relativeName p == "Proof.hs" then
        "module Proof where\nimport Kyyn.Evolution\nmain :: IO ()\nmain = print (EvolutionOutput () [])\n" else b) | (p,b) <- captured]
  forM_ [("wrong-type",badType),("private-constructor",badConstructor)] $ \(label,entries) -> do
    (nativeRejected,_,_) <- native label entries
    unless (nativeRejected /= ExitSuccess) (fail (label ++ " compiled under GHC"))
    rejected <- compileGuestFiles entries
    case rejected of
      Right (Left _) -> pure ()
      Left failure -> fail (show failure)
      Right (Right _) -> fail (label ++ " compiled under MicroHs")
  putStr expected
  putStrLn "GHC and MicroHs agree; wrong binding types and private constructors are rejected."

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
