{-# LANGUAGE GHC2021, GADTs, LambdaCase #-}
{-# OPTIONS_GHC -Werror #-}
module Kyyn.MicroHs.Interpreter.SchemaInspection (runSchemaInspectionIO) where

import Control.Monad (forM_)
import Data.Coerce (coerce)
import qualified Data.ByteString as Bytes
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (checkContract)
import Kyyn.Domain.DataType (DataType)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure(..))
import Kyyn.Domain.Path (scopePath, scopedPath, RelativePath)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Plugin (QualifiedTypeName(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.MicroHs.Inspection (InspectionError(..), inspectDataType)
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem, withTemporaryScope, writeBytes)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (sourceFiles)
import Kyyn.Plumbing.Capability.SchemaInspection
import Kyyn.Plumbing.Capability.SchemaInspection.Metadata (evaluateMetadata)

runSchemaInspectionIO
  :: (IOE :> es, FileSystem :> es, GuestCompilation :> es, GuestExecution :> es, Failure :> es)
  => GuestToolchain -> Eff (SchemaInspection : es) a -> Eff es a
runSchemaInspectionIO toolchain = interpret $ \_ -> \case
  InspectSchema source -> do
    inspected <- inspect toolchain (sourceFiles (schemaSources source)) (selectedType source)
    case inspected of
      Left diagnostics -> pure (Left diagnostics)
      Right (structure,closure) -> do
        metadata <- evaluateMetadata (schemaSources source)
        pure ((\contract -> InspectedSchema contract closure) <$> (metadata >>= checkContract structure))
  InspectType source selected -> do
    inspected <- inspect toolchain (files source) (coerce selected)
    pure (inspected >>= \(structure,closure) ->
      (\contract -> InspectedSchema contract closure) <$> checkContract structure (SchemaMetadata [] [] []))

inspect :: (IOE :> es, FileSystem :> es, Failure :> es)
  => GuestToolchain -> [(RelativePath,Bytes.ByteString)] -> String
  -> Eff es (Either [Diagnostic] (DataType,[RelativePath]))
inspect (GuestToolchain compiler) sources selected =
  withTemporaryScope $ \scope -> do
    forM_ sources $ \(path,bytes) -> writeBytes scope path bytes
    inspected <- liftIO (inspectDataType (scopePath compiler) [scopePath scope] selected)
    case inspected of
      Left (NativeError message) -> raiseFailure (CompilerUnavailable message)
      Left (CompilerError message) -> pure (Left [errorDiagnostic "schema.compiler-rejected" message])
      Left (TypeNotSupported message) -> pure (Left [errorDiagnostic "schema.unsupported" message])
      Right (structure,loaded) -> do
        let closure = [path | (path,_) <- sources, scopedPath scope path `elem` loaded]
        pure (Right (structure,closure))
