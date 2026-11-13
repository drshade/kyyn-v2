module Kyyn.Domain.Failure
  ( OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..)
  , StorageDiagnostic(..), StorageOperation(..), operationalDiagnostic ) where

import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)

data OperationalFailure = RuntimeUnavailable ProcessDiagnostic | StorageUnavailable StorageDiagnostic
  | CompilerUnavailable String
  | GitUnavailable String
  deriving (Eq, Show)

data ProcessDiagnostic = ProcessDiagnostic
  { operation :: ProcessOperation
  , message :: String
  } deriving (Eq, Show)

data ProcessOperation = StartProcess | StopProcess | WriteInput | CloseInput | ReadOutput | WaitForExit
  deriving (Eq, Show)

data StorageDiagnostic = StorageDiagnostic StorageOperation FilePath String deriving (Eq, Show)
data StorageOperation = CreateTemporaryScope | RemoveTemporaryScope | ReadFile | WriteFile | ReadDirectoryTree | ListDirectory | CreateUniqueDirectory | CreateDirectory | ReplaceFile | ReplaceDirectoryTree | EnsureDirectory | InspectEntry
  deriving (Eq, Show)

-- The CLI and durable run diagnostics share the same user-facing failure.
operationalDiagnostic :: OperationalFailure -> Diagnostic
operationalDiagnostic failure = case failure of
  RuntimeUnavailable (ProcessDiagnostic operation message) -> errorDiagnostic "runtime.unavailable" (show operation ++ ": " ++ message)
  StorageUnavailable (StorageDiagnostic operation path message) -> errorDiagnostic "storage.unavailable" (show operation ++ " " ++ path ++ ": " ++ message)
  CompilerUnavailable message -> errorDiagnostic "compiler.unavailable" message
  GitUnavailable message -> errorDiagnostic "git.unavailable" message
