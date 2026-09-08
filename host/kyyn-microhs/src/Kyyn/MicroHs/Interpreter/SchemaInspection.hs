{-# LANGUAGE GHC2021, GADTs #-}
{-# OPTIONS_GHC -Werror #-}
module Kyyn.MicroHs.Interpreter.SchemaInspection (runSchemaInspectionIO) where

import Control.Monad (forM_)
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (checkContract)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure(..))
import Kyyn.Domain.Path (scopePath)
import Kyyn.MicroHs.Inspection (InspectionError(..), inspectDataType)
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem, withTemporaryScope, writeBytes)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (sourceFiles)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import Kyyn.Plumbing.Capability.SchemaInspection
import Kyyn.Plumbing.Capability.SchemaInspection.Metadata (evaluateMetadata)

runSchemaInspectionIO
  :: (IOE :> es, FileSystem :> es, GuestCompilation :> es, ProcessExecution :> es, Failure :> es)
  => GuestToolchain -> Eff (SchemaInspection : es) a -> Eff es a
runSchemaInspectionIO (GuestToolchain compiler) = interpret $ \_ (InspectSchema source) ->
  withTemporaryScope $ \scope -> do
    let sources = schemaSources source
    forM_ (sourceFiles sources) $ \(path,bytes) -> writeBytes scope path bytes
    inspected <- liftIO (inspectDataType (scopePath compiler) [scopePath scope] (selectedType source))
    case inspected of
      Left (NativeError message) -> raiseFailure (CompilerUnavailable message)
      Left (CompilerError message) -> pure (Left [errorDiagnostic "schema.compiler-rejected" message])
      Left (TypeNotSupported message) -> pure (Left [errorDiagnostic "schema.unsupported" message])
      Right structure -> do
        metadata <- evaluateMetadata sources
        pure (metadata >>= checkContract structure)
