{-# LANGUAGE GHC2021, DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
{-# OPTIONS_GHC -Werror #-}
module Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation) where

import Control.Monad (forM_)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as Bytes
import Numeric (showHex)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.MicroHs.CompilerDiagnostic (compilerMessage)
import Kyyn.Domain.Failure
import Kyyn.Domain.Path
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import qualified Kyyn.MicroHs.Toolchain as Toolchain
import Kyyn.Plumbing.Capability.Failure
import Kyyn.Plumbing.Capability.FileSystem
import Kyyn.Plumbing.Capability.GuestCompilation
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process

runGuestCompilation
  :: (FileSystem :> es, Process.ProcessExecution :> es, Failure :> es)
  => GuestToolchain -> Maybe DirectoryScope -> Eff (GuestCompilation : es) a -> Eff es a
runGuestCompilation (GuestToolchain toolchain) cache = interpret $ \_ -> \case
  CompileGuest sources -> do
    let sourceDirectory = "sources"
        sourcePath path = checkedPath (sourceDirectory ++ "/" ++ relativeName path)
        output = checkedPath "program.comb"
        root = scopePath toolchain
        compilerEnvironment = [("MHSDIR", root), ("MHSCPPHS", root ++ "/bin/cpphs"), ("LC_ALL", "C.UTF-8"), ("PATH", "")]
        -- Bare -a clears package search paths; bare -i clears source search paths.
        arguments = ["-a", "-i", "-i" ++ sourceDirectory, "-i" ++ root ++ "/lib",
          "-DMIN_VERSION_base(x,y,z)=1"] ++
          [relativeName (sourcePath (selectedEntry sources)), "-o" ++ relativeName output]
        identity = BuildIdentity Toolchain.toolchainRevision (sourceIdentity sources)
        key = checkedPath (concatMap hex (Bytes.unpack (SHA256.hash
          (Text.encodeUtf8 (Text.pack (show (identity, arguments, compilerEnvironment)))))) ++ ".comb")
        result bytes = Right (CompiledProgram identity (output,bytes))
    cached <- case cache of
      Nothing -> pure Nothing
      Just directory -> readOptionalBytes directory key
    case cached of
      Just bytes | not (Bytes.null bytes) -> pure (result bytes)
      _ -> withTemporaryScope $ \scope -> do
        forM_ (sourceFiles sources) $ \(path, bytes) -> writeBytes scope (sourcePath path) bytes
        (stdout, Process.ProcessExit status stderr) <- Process.withProcess
          (Process.ProcessSpec (root ++ "/bin/mhs") arguments (scopePath scope) compilerEnvironment) $ do
            Process.closeStdin
            stdout <- Process.collectStdout
            exit <- Process.awaitExit
            pure (stdout, exit)
        case status of
          0 -> do
            bytes <- readBytes scope output
            if Bytes.null bytes then broken "compiler produced an empty artifact" else do
              forM_ cache $ \directory -> do
                ignored <- readOptionalBytes directory (checkedPath ".gitignore")
                case ignored of
                  Nothing -> replaceBytes directory (checkedPath ".gitignore") "*\n"
                  Just _ -> pure ()
                replaceBytes directory key bytes
              pure (result bytes)
          1 -> case Text.decodeUtf8' (stderr <> stdout) of
            Left _ -> broken "compiler emitted invalid UTF-8 diagnostics"
            Right message -> pure (Left [errorDiagnostic "guest.compiler-rejected" (compilerMessage (Text.unpack message))])
          _ -> broken ("compiler terminated with exit status " ++ show status)

  where
    hex byte = let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits
    broken message = raiseFailure (RuntimeUnavailable (ProcessDiagnostic WaitForExit message))
    -- Only fixed names and a fixed prefix joined to an already checked path enter here.
    checkedPath = either error id . relativePath
