{-# LANGUAGE GADTs, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection) where

import Kyyn.Types.Wire (decodeWire)
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as Bytes
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Guest (checkGuest)
import Kyyn.Types.Guest (GuestRequest(..))
import Kyyn.Plumbing.Capability.GuestInspection
import Kyyn.Plumbing.Capability.GuestExecution
import Kyyn.Plumbing.Capability.Failure (Failure)

runGuestInspection :: (GuestExecution :> es, Failure :> es) => Eff (GuestInspection : es) a -> Eff es a
runGuestInspection = interpret $ \_ (DescribeGuest program) -> do
  response <- executeCompiledEntry "describe" program
    (Bytes.toStrict (encode Describe))
  pure $ case decodeWire response of
    Left problem -> Left [errorDiagnostic "guest.description" problem]
    Right description -> checkGuest description
