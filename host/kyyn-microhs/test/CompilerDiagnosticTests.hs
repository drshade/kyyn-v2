module Main where

import Control.Monad (unless, forM_)
import Data.List (isInfixOf)
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Path
import Kyyn.MicroHs.CompilerDiagnostic
import Kyyn.MicroHs.Toolchain
import Kyyn.MicroHs.Inspection
import Kyyn.MicroHs.ApiInspection
import CompilationTests (testCompilation)
import System.Environment (getEnv)
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = do
  let message = "Tools.hs:33:73: Cannot satisfy constraint: Probability ~ Double\n     fully qualified: Probability ~ Double\n"
      stack = "CallStack (from HasCallStack):\n  error, called at Compiler.hs:1:1 in main:Compiler\nHasCallStack backtrace:\n  throwIO, called at Exception.hs:1:1 in base:Exception\n"
      assert label value = unless value (fail label)
  assert "strip frames, retain complete diagnostic" (compilerMessage (message ++ stack) == message)
  assert "retain subsequent diagnostics" (compilerMessage (message ++ stack ++ "another compiler error\n") == message ++ "another compiler error\n")
  assert "retain mentions of stack terminology" (compilerMessage "Tools.hs:1:1: Not in scope: CallStack\n" == "Tools.hs:1:1: Not in scope: CallStack\n")
  forM_ ["schema","tool","validator","query","evolution"] $ \context ->
    assert "context preserves source diagnostic" (compilerContext context (errorDiagnostic "guest.compiler-rejected" message) == errorDiagnostic (context ++ ".compiler-rejected") message)
  assert "unrelated errors unchanged" (compilerContext "tool" (errorDiagnostic "schema.unsupported" message) == errorDiagnostic "schema.unsupported" message)
  compiler <- getEnv "KYYN_TEST_TOOLCHAIN"
  repo <- getEnv "KYYN_TEST_ROOT"
  let clean text = not ("CallStack" `isInfixOf` text) && not ("backtrace:" `isInfixOf` text) && "IllTyped.hs" `isInfixOf` text
      fixtures = repo ++ "/tests/integration/codecs"
  inspected <- inspectDataType compiler [fixtures] "IllTyped.Root"
  case inspected of
    Left (CompilerError text) -> assert "native type inspection" (clean text)
    other -> fail (show other)
  api <- inspectApi compiler [fixtures] ["IllTyped"]
  case api of
    Left (ApiCompilerError text) -> assert "native API inspection" (clean text)
    other -> fail (show other)
  withSystemTempDirectory "kyyn-compiler-diagnostics" $ \temporary -> do
    scope <- either fail pure (directoryScope temporary)
    toolchain <- GuestToolchain <$> either fail pure (directoryScope compiler)
    testCompilation scope toolchain
  putStrLn "Compiler diagnostics preserve messages, remove stacks, and retain contextual codes."
