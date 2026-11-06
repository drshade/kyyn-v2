{-# LANGUAGE GADTs, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection) where

import Data.Aeson (encode, object, (.=), eitherDecodeStrict')
import qualified Data.ByteString.Lazy as Bytes
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Guest (checkGuest)
import Kyyn.Plumbing.Capability.GuestInspection
import Kyyn.Plumbing.Capability.GuestExecution
import Kyyn.Plumbing.Capability.Failure (Failure)

runGuestInspection :: (GuestExecution :> es, Failure :> es) => Eff (GuestInspection : es) a -> Eff es a
runGuestInspection = interpret $ \_ (DescribeGuest program) -> do
  response <- executeCompiledEntry "describe" program
    (Bytes.toStrict (encode (object ["operation" .= ("describe" :: String)])))
  pure $ case eitherDecodeStrict' response of
    Left problem -> Left [errorDiagnostic "guest.description" problem]
    Right description -> checkGuest description
