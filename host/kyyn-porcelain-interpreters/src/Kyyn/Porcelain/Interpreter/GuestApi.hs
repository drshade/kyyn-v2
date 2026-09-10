{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.GuestApi (runGuestApi) where

import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Path (DirectoryScope, relativePath)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem, readOptionalBytes)
import Kyyn.Plumbing.Protocol.GuestApi (decodeCatalogue)
import Kyyn.Porcelain.Capability.GuestApi (GuestApi(..))

runGuestApi :: (FileSystem :> es, DhallHandling :> es)
  => DirectoryScope -> Eff (GuestApi : es) a -> Eff es a
runGuestApi runtime = interpret $ \_ -> \case
  ReadCatalogue -> case relativePath "guest-api.dhall" of
    Left message -> pure (Left [errorDiagnostic "guest.catalogue" message])
    Right path -> do
      contents <- readOptionalBytes runtime path
      case contents of
        Nothing -> pure (Left [errorDiagnostic "guest.catalogue-missing"
          "No guest API catalogue in the selected runtime; reinstall Kyyn or check --runtime DIRECTORY"])
        Just bytes -> decodeCatalogue bytes
