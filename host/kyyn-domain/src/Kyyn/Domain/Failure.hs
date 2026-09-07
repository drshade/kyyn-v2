module Kyyn.Domain.Failure
  ( OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..) ) where

data OperationalFailure = RuntimeUnavailable ProcessDiagnostic
  deriving (Eq, Show)

data ProcessDiagnostic = ProcessDiagnostic
  { operation :: ProcessOperation
  , message :: String
  } deriving (Eq, Show)

data ProcessOperation = StartProcess | StopProcess | WriteInput | CloseInput | ReadOutput | WaitForExit
  deriving (Eq, Show)
