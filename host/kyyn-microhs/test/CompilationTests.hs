{-# LANGUAGE DataKinds, OverloadedStrings, GADTs, LambdaCase, DisambiguateRecordFields #-}
module CompilationTests (testCompilation) where

import Control.Monad (unless, forM_)
import qualified Data.Text as Text
import qualified Data.ByteString as Bytes
import Effectful (Eff, runEff)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Failure
import Kyyn.Domain.Path
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation)
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution (executeCompiled)
import Kyyn.Plumbing.Capability.ProcessExecution
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import System.Directory (listDirectory)

testCompilation :: DirectoryScope -> GuestToolchain -> IO ()
testCompilation temporary toolchain = do
  let path = either error id . relativePath
      make = guestSources (path "Program.hs")
      files = [(path "Program.hs", "{-# LANGUAGE CPP #-}\nmodule Program where\nimport Helper\n#define MESSAGE message\nmain :: IO ()\nmain = putStr (\"9\\n\" ++ MESSAGE ++ \"\\n0\\n0\\n\")\n"),
               (path "Helper.hs", "module Helper where\nmessage :: String\nmessage = \"captured\"\n")]
      compileWith selected sources = runEff . runFailure . runProcessExecutionIO . runFileSystemIO temporary . runGuestCompilation selected Nothing $
        compileGuest sources
      compile = compileWith toolchain
      invoke entry = runEff . runFailure . runProcessExecutionIO . runFileSystemIO temporary . runGuestExecution toolchain $
        executeCompiled entry Bytes.empty
      assert label ok = unless ok (fail label)
      expectSourceFailure label input = case input of
        Left _ -> pure ()
        Right _ -> fail label
  sources <- either fail pure (make files)
  reordered <- either fail pure (make (reverse files))
  assert "source identity depends on order" (sourceIdentity sources == sourceIdentity reordered)
  changed <- either fail pure (make (map (\(name, bytes) -> (name, bytes <> "\n")) files))
  assert "changed bytes must change source identity" (sourceIdentity sources /= sourceIdentity changed)
  alternateEntry <- either fail pure (guestSources (path "Helper.hs") files)
  assert "selected entry must change source identity" (sourceIdentity sources /= sourceIdentity alternateEntry)
  expectSourceFailure "duplicate source path accepted" (make (files ++ take 1 files))
  expectSourceFailure "missing entry accepted" (make [])
  expectSourceFailure "file/directory collision accepted" (make (files ++ [(path "Helper.hs/Child.hs", "")]))
  plain <- compile sources >>= either (fail . show) (either (fail . show) pure)
  forM_ [plain, plain] $ \entry -> do
    output <- invoke entry
    assert ("captured CPP dependency/evaluator output: " ++ show output) (output == Right ("captured\n", ProcessExit 0 ""))
  forM_ ["module Program where\nmain :: IO ()\nmain = pure True\n",
         "module Program where\nimport Uncaptured\nmain = missing\n"] $ \source -> do
    invalid <- either fail pure (make [(path "Program.hs", source)])
    rejected <- compile invalid
    case rejected of
      Right (Left [Diagnostic{code = "guest.compiler-rejected", message}]) ->
        assert "compiler diagnostic must retain message without stacks" (not (Text.null message) && not ("CallStack" `Text.isInfixOf` message) && not ("backtrace:" `Text.isInfixOf` message))
      Left err -> fail ("source rejection became operational failure: " ++ show err)
      _ -> fail "invalid captured code compiled"
  absentScope <- either fail pure (directoryScope (scopePath temporary ++ "/absent-toolchain"))
  missing <- compileWith (GuestToolchain absentScope) sources
  case missing of
    Left (RuntimeUnavailable ProcessDiagnostic{operation = StartProcess}) -> pure ()
    _ -> fail "missing compiler must be an operational failure"
  forM_ [(-11, "terminated"), (2, "unexpected status"), (1, Bytes.pack [255])] $ \(status, bytes) -> do
    outcome <- runEff . runFailure . compilerExit status bytes . runFileSystemIO temporary . runGuestCompilation toolchain Nothing $
      compileGuest sources
    case outcome of
      Left (RuntimeUnavailable ProcessDiagnostic{operation = WaitForExit}) -> pure ()
      _ -> fail "compiler crash or malformed diagnostic must be operational failure"
  remaining <- listDirectory (scopePath temporary)
  assert "compilation or invocation leaked temporary files" (null remaining)
  assert "source digest is SHA-256" (Bytes.length (sourceIdentity sources) == 32)
  putStrLn "Captured compilation tests passed: CPP, identity, reusable bytecode and diagnostics."

compilerExit :: Int -> Bytes.ByteString -> Eff (ProcessExecution : es) a -> Eff es a
compilerExit status diagnostics = interpret $ \env (WithProcess _ action) ->
  localSeqUnlift env $ \unlift -> unlift $ interpret (\_ -> \case
    WriteStdin _ -> pure ()
    CloseStdin -> pure ()
    ReadStdout -> pure Nothing
    AwaitExit -> pure (ProcessExit status diagnostics)) action
