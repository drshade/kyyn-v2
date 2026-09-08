module Kyyn.Domain.Failure
  ( OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..)
  , StorageDiagnostic(..), StorageOperation(..) ) where

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
data StorageOperation = CreateTemporaryScope | RemoveTemporaryScope | ReadFile | WriteFile | ReadDirectoryTree
  deriving (Eq, Show)
