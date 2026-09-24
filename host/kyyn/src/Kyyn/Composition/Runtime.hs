{-# LANGUAGE DataKinds #-}
module Kyyn.Composition.Runtime (Base, Runtime, runBase, runRuntime, withRuntime, finish) where

import Effectful (Eff, IOE, runEff)
import System.Environment (setEnv)
import System.FilePath ((</>))
import Kyyn.Configuration (Host(..))
import Kyyn.Composition.Timings
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Path (directoryScope)
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation)
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.MicroHs.Interpreter.SchemaInspection (runSchemaInspectionIO)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem, readTree)
import Kyyn.Plumbing.Capability.Git (Git)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Git (runGit)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.RootStore (RootStore)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Surfaces.Result (Response, operationalFailure, refusal)

type Base = '[RootStore, DhallHandling, Git, FileSystem, ProcessExecution, Failure, IOE]
type Runtime = SchemaInspection ': GuestCompilation ': GuestExecution ': Base

runBase :: Host -> Eff Base a -> IO (Either OperationalFailure a)
runBase (Host executable environment temp _ _ _ timings) = runEff . runFailure . runProcessExecutionIO . observeProcesses timings
  . runFileSystemIO temp . runGit executable environment . runDhallHandling . runRootStore

runRuntime :: Host -> GuestToolchain -> Eff Runtime a -> IO (Either OperationalFailure a)
runRuntime host@(Host _ _ _ _ cache inspection timings) toolchain = runBase host
  . runGuestExecution toolchain . observeExecutions timings
  . runGuestCompilation toolchain cache . observeCompilations timings . runSchemaInspectionIO toolchain inspection

finish :: IO (Either OperationalFailure Response) -> IO Response
finish action = either operationalFailure id <$> action

withRuntime :: Host -> (GuestToolchain -> FileTree -> IO Response) -> IO Response
withRuntime (Host _ _ temp runtime _ _ _) action = case (directoryScope (runtime </> "microhs"), directoryScope (runtime </> "sdk")) of
  (Right toolchain,Right sdkScope) -> do
    setEnv "MHSCPPHS" (runtime </> "microhs/bin/cpphs")
    loaded <- runEff . runFailure . runFileSystemIO temp $ readTree sdkScope
    case loaded of
      Left failure -> pure (operationalFailure failure)
      Right sdk -> action (GuestToolchain toolchain) sdk
  _ -> pure (refusal [errorDiagnostic "setup.runtime" "Runtime must resolve to an absolute directory"])
