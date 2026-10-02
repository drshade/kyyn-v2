{-# LANGUAGE GHC2021, GADTs, LambdaCase #-}
{-# OPTIONS_GHC -Werror #-}
module Kyyn.MicroHs.Interpreter.SchemaInspection (runSchemaInspectionIO) where

import Control.Monad (forM_, forM)
import Data.Bifunctor (first)
import Data.Coerce (coerce)
import qualified Data.ByteString as Bytes
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (checkContract)
import Kyyn.Domain.DataType (DataType)
import Kyyn.Domain.Diagnostic (Diagnostic, compilerContext)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure(..))
import Kyyn.Domain.Path (scopePath, scopedPath, RelativePath, relativeName)
import Data.List (isSuffixOf)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Plugin (QualifiedTypeName(..), PluginEntryKind, PluginSignature)
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.MicroHs.Inspection (InspectionError(..), inspectDataType, inspectModuleImports, inspectPluginSignature, inspectionSettings)
import Kyyn.MicroHs.Interpreter.InspectionCache (InspectionCache, cachedInspection)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Protocol.Inspection (encodeInspection, decodeInspection, encodePluginSignature, decodePluginSignature)
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem, withTemporaryScope, writeBytes)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (sourceFiles)
import Kyyn.Plumbing.Capability.SchemaInspection
import Kyyn.Plumbing.Capability.SchemaInspection.Metadata (evaluateMetadata)

runSchemaInspectionIO
  :: (IOE :> es, DhallHandling :> es, FileSystem :> es, GuestCompilation :> es, GuestExecution :> es, Failure :> es)
  => GuestToolchain -> Maybe InspectionCache -> Eff (SchemaInspection : es) a -> Eff es a
runSchemaInspectionIO toolchain cache = interpret $ \_ -> \case
  InspectImports tree -> withTemporaryScope $ \scope -> do
    forM_ (files tree) $ \(path,bytes) -> writeBytes scope path bytes
    let GuestToolchain compiler = toolchain
    results <- forM [path | (path,_) <- files tree, ".hs" `isSuffixOf` relativeName path] $ \path -> do
      result <- liftIO (inspectModuleImports (scopePath compiler) (scopedPath scope path))
      case result of
        Left (NativeError message) -> raiseFailure (CompilerUnavailable message)
        Left (CompilerError message) -> pure (Left [errorDiagnostic "guest.imports" message])
        Left (TypeNotSupported message) -> pure (Left [errorDiagnostic "guest.imports" message])
        Right imports -> pure (Right (path,imports))
    pure (sequence results)
  InspectSchema source -> do
    inspected <- inspect toolchain cache (sourceFiles (schemaSources source)) (selectedType source)
    case inspected of
      Left diagnostics -> pure (Left (map (compilerContext "schema") diagnostics))
      Right (structure,closure) -> do
        metadata <- evaluateMetadata (schemaSources source)
        pure (first (map (compilerContext "schema")) ((\contract -> InspectedSchema contract closure) <$> (metadata >>= checkContract structure)))
  InspectType source selected -> do
    inspected <- inspect toolchain cache (files source) (coerce selected)
    pure (inspected >>= \(structure,closure) ->
      (\contract -> InspectedSchema contract closure) <$> checkContract structure (SchemaMetadata [] [] []))
  InspectPluginFunction source kind selected -> fmap (fmap fst) (inspectFunction toolchain cache (files source) kind selected)

inspectFunction :: (IOE :> es, DhallHandling :> es, FileSystem :> es, Failure :> es)
  => GuestToolchain -> Maybe InspectionCache -> [(RelativePath,Bytes.ByteString)] -> PluginEntryKind -> String
  -> Eff es (Either [Diagnostic] (PluginSignature,[RelativePath]))
inspectFunction (GuestToolchain compiler) cache sources kind selected =
  cachedInspection cache "plugin-signature" (show kind ++ ":" ++ selected)
    (show kind ++ inspectionSettings (scopePath compiler) selected) sources encodePluginSignature decode $
  withTemporaryScope $ \scope -> do
    forM_ sources $ \(path,bytes) -> writeBytes scope path bytes
    inspected <- liftIO (inspectPluginSignature (scopePath compiler) [scopePath scope] kind selected)
    case inspected of
      Left (NativeError message) -> raiseFailure (CompilerUnavailable message)
      Left (CompilerError message) -> pure (Left [errorDiagnostic "guest.compiler-rejected" (selected ++ ": " ++ message)])
      Left (TypeNotSupported message) -> pure (Left [errorDiagnostic "plugin.signature-invalid" message])
      Right (signature,loaded) -> pure (Right (signature,[path | (path,_) <- sources, scopedPath scope path `elem` loaded]))
  where
    decode bytes = do
      result <- decodePluginSignature bytes
      pure (result >>= \value@(_,closure) -> if all (`elem` map fst sources) closure
        then Right value else Left [errorDiagnostic "inspection.cache-invalid" "Closure is outside captured sources"])

inspect :: (IOE :> es, DhallHandling :> es, FileSystem :> es, Failure :> es)
  => GuestToolchain -> Maybe InspectionCache -> [(RelativePath,Bytes.ByteString)] -> String
  -> Eff es (Either [Diagnostic] (DataType,[RelativePath]))
inspect (GuestToolchain compiler) cache sources selected =
  cachedInspection cache "inspection" selected (inspectionSettings (scopePath compiler) selected) sources
    encodeInspection decode $
  withTemporaryScope $ \scope -> do
    forM_ sources $ \(path,bytes) -> writeBytes scope path bytes
    inspected <- liftIO (inspectDataType (scopePath compiler) [scopePath scope] selected)
    case inspected of
      Left (NativeError message) -> raiseFailure (CompilerUnavailable message)
      Left (CompilerError message) -> pure (Left [errorDiagnostic "guest.compiler-rejected" message])
      Left (TypeNotSupported message) -> pure (Left [errorDiagnostic "schema.unsupported" message])
      Right (structure,loaded) -> do
        let closure = [path | (path,_) <- sources, scopedPath scope path `elem` loaded]
        pure (Right (structure,closure))
  where
    decode bytes = do
      result <- decodeInspection bytes
      pure (result >>= \value@(_,closure) -> if all (`elem` map fst sources) closure
        then Right value else Left [errorDiagnostic "inspection.cache-invalid" "Closure is outside captured sources"])
