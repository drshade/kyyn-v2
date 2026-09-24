{-# LANGUAGE GHC2021, GADTs #-}
{-# OPTIONS_GHC -Werror #-}
module Kyyn.MicroHs.Interpreter.ApiInspection (runApiInspectionIO) where

import Control.Monad (forM_)
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure(..))
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Path (scopePath)
import Kyyn.MicroHs.ApiInspection (inspectApi, ApiError(..), apiInspectionSettings)
import Kyyn.MicroHs.Interpreter.InspectionCache (InspectionCache, cachedInspection)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Protocol.GuestApi (encodeCatalogue, decodeCatalogue)
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.Plumbing.Capability.ApiInspection (ApiInspection(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem, withTemporaryScope, writeBytes)

runApiInspectionIO
  :: (IOE :> es, DhallHandling :> es, FileSystem :> es, Failure :> es)
  => GuestToolchain -> Maybe InspectionCache -> Eff (ApiInspection : es) a -> Eff es a
runApiInspectionIO (GuestToolchain compiler) cache = interpret $ \_ (InspectApiModules sources selected) ->
  cachedInspection cache "api-inspection" (show selected) (apiInspectionSettings (scopePath compiler) selected) (files sources)
    encodeCatalogue decodeCatalogue $
  withTemporaryScope $ \scope -> do
    forM_ (files sources) $ \(path,bytes) -> writeBytes scope path bytes
    inspected <- liftIO (inspectApi (scopePath compiler) [scopePath scope] selected)
    case inspected of
      Left (ApiNativeError message) -> raiseFailure (CompilerUnavailable message)
      Left (ApiCompilerError message) -> pure (Left [errorDiagnostic "guest.api-compiler-rejected" message])
      Left (ApiSourceError message) -> pure (Left [errorDiagnostic "guest.api-source-rejected" message])
      Right modules -> pure (Right modules)
