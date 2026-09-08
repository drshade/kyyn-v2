{-# LANGUAGE GHC2021, DataKinds, GADTs #-}
{-# OPTIONS_GHC -Werror #-}
module Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation) where

import Control.Monad (forM_)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Failure
import Kyyn.Domain.Path
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import qualified Kyyn.MicroHs.Toolchain as Toolchain
import Kyyn.Plumbing.Capability.Failure
import Kyyn.Plumbing.Capability.FileSystem
import Kyyn.Plumbing.Capability.GuestCompilation
import qualified Kyyn.Plumbing.Capability.GuestCompilation.Types as Types
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process

runGuestCompilation
  :: (FileSystem :> es, Process.ProcessExecution :> es, Failure :> es)
  => GuestToolchain -> Eff (GuestCompilation : es) a -> Eff es a
runGuestCompilation (GuestToolchain toolchain) = interpret $ \_ (CompileGuest sources options@BuildOptions{compressCombinators}) ->
  withTemporaryScope $ \scope -> do
    let sourceDirectory = "sources"
        sourcePath path = checkedPath (sourceDirectory ++ "/" ++ relativeName path)
        output = checkedPath "program.comb"
        root = scopePath toolchain
        compilerEnvironment = [("MHSDIR", root), ("MHSCPPHS", root ++ "/bin/cpphs"), ("LC_ALL", "C.UTF-8"), ("PATH", "")]
        arguments = ["-a", "-i", "-i" ++ sourceDirectory, "-i" ++ root ++ "/lib"] ++
          ["-z" | compressCombinators] ++
          [relativeName (sourcePath (selectedEntry sources)), "-o" ++ relativeName output]
    forM_ (sourceFiles sources) $ \(path, bytes) -> writeBytes scope (sourcePath path) bytes
    (stdout, Process.ProcessExit status stderr) <- Process.withProcess
      (Process.ProcessSpec (root ++ "/bin/mhs") arguments (scopePath scope) compilerEnvironment) $ do
        Process.closeStdin
        stdout <- Process.collectStdout
        result <- Process.awaitExit
        pure (stdout, result)
    case status of
      0 -> do
        bytes <- readBytes scope output
        if Bytes.null bytes
          then broken "compiler produced an empty artifact"
          else pure (Right (Types.CompiledEntry
            (BuildIdentity Toolchain.toolchainRevision (sourceIdentity sources) options)
            (output, bytes) (root ++ "/bin/mhseval") ["+RTS", "-r" ++ relativeName output, "-RTS"] [("LC_ALL", "C.UTF-8"), ("PATH", "")]))
      1 -> case Text.decodeUtf8' (stderr <> stdout) of
        Left _ -> broken "compiler emitted invalid UTF-8 diagnostics"
        Right message -> pure (Left [Diagnostic "guest.compiler-rejected" (Text.unpack message)])
      _ -> broken ("compiler terminated with exit status " ++ show status)
  where
    broken message = raiseFailure (RuntimeUnavailable (ProcessDiagnostic WaitForExit message))
    checkedPath = either error id . relativePath
