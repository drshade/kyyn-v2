{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.DhallHandling
  ( DhallHandling(..), decodeValue, encodeValue, decodeBinaryValue, decodeBinaryEnvelope, encodeBinaryValue, renderType ) where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.ByteString (ByteString)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.DataType (Shape)
import Kyyn.Domain.Diagnostic (Diagnostic)

data DhallHandling :: Effect where
  DecodeValue :: Shape -> Text -> DhallHandling m (Either [Diagnostic] Value)
  EncodeValue :: Shape -> Value -> DhallHandling m (Either [Diagnostic] Text)
  DecodeBinaryValue :: Shape -> ByteString -> DhallHandling m (Either [Diagnostic] Value)
  EncodeBinaryValue :: Shape -> Value -> DhallHandling m (Either [Diagnostic] ByteString)
  -- | Decode once; checked header metadata determines the body's expected shape.
  DecodeBinaryEnvelope :: Shape -> (Value -> Either [Diagnostic] Shape) -> ByteString
    -> DhallHandling m (Either [Diagnostic] Value)
  RenderType :: Shape -> DhallHandling m Text

type instance DispatchOf DhallHandling = Dynamic

decodeValue :: DhallHandling :> es => Shape -> Text -> Eff es (Either [Diagnostic] Value)
decodeValue shape = send . DecodeValue shape

encodeValue :: DhallHandling :> es => Shape -> Value -> Eff es (Either [Diagnostic] Text)
encodeValue shape = send . EncodeValue shape

renderType :: DhallHandling :> es => Shape -> Eff es Text
renderType = send . RenderType

decodeBinaryValue :: DhallHandling :> es => Shape -> ByteString -> Eff es (Either [Diagnostic] Value)
decodeBinaryValue shape = send . DecodeBinaryValue shape

encodeBinaryValue :: DhallHandling :> es => Shape -> Value -> Eff es (Either [Diagnostic] ByteString)
encodeBinaryValue shape = send . EncodeBinaryValue shape

decodeBinaryEnvelope :: DhallHandling :> es => Shape -> (Value -> Either [Diagnostic] Shape)
  -> ByteString -> Eff es (Either [Diagnostic] Value)
decodeBinaryEnvelope shape bodyShape = send . DecodeBinaryEnvelope shape bodyShape
