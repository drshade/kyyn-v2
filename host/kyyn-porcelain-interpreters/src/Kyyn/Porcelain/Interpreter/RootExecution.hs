{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as Bytes
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (rootType, rootSchema)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Domain.Root (Root(..), RootDefinition(..), CheckedValue(..))
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest, withCompiledEntry)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution, ProcessExit(..), writeStdin, closeStdin, collectStdout, awaitExit)
import Kyyn.Plumbing.Protocol.Validation (validationSources, decodeReport)
import Kyyn.Porcelain.Capability.RootStore (RootStore, readRootDefinition, loadRootValueForChecking)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution(..))

runRootExecution
  :: (RootStore :> es, GuestCompilation :> es, FileSystem :> es, ProcessExecution :> es, Failure :> es)
  => FileTree -> Eff (RootExecution : es) a -> Eff es a
runRootExecution sdk = interpret $ \_ (ValidateRoot root@(Root contract _ code)) -> runExceptT $ do
  RootDefinition _ _ selected authored <- ExceptT (readRootDefinition code)
  CheckedValue _ value <- ExceptT (loadRootValueForChecking root)
  sources <- ExceptT (pure (either (Left . pure . errorDiagnostic "root.validation-source") Right
    (validationSources (rootType (rootSchema contract)) selected (files authored ++ files sdk))))
  entry <- ExceptT (compileGuest sources)
  ExceptT $ withCompiledEntry entry $ do
    writeStdin (Bytes.toStrict (encode value))
    closeStdin
    output <- collectStdout
    ProcessExit status diagnostics <- awaitExit
    if status /= 0
      then raiseFailure (RuntimeUnavailable (ProcessDiagnostic WaitForExit
        (selected ++ " exited " ++ show status ++ ": " ++ show diagnostics)))
      else case decodeReport output of
        Left message -> raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput (selected ++ ": " ++ message)))
        Right report -> pure (Right report)
