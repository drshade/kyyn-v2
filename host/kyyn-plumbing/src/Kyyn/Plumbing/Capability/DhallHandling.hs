{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.DhallHandling
  ( DhallHandling(..), decodeValue, encodeValue, renderType ) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.DataType (Shape)
import Kyyn.Domain.Diagnostic (Diagnostic)

data DhallHandling :: Effect where
  DecodeValue :: Shape -> Text -> DhallHandling m (Either [Diagnostic] Value)
  EncodeValue :: Shape -> Value -> DhallHandling m (Either [Diagnostic] Text)
  RenderType :: Shape -> DhallHandling m Text

type instance DispatchOf DhallHandling = Dynamic

decodeValue :: DhallHandling :> es => Shape -> Text -> Eff es (Either [Diagnostic] Value)
decodeValue shape = send . DecodeValue shape

encodeValue :: DhallHandling :> es => Shape -> Value -> Eff es (Either [Diagnostic] Text)
encodeValue shape = send . EncodeValue shape

renderType :: DhallHandling :> es => Shape -> Eff es Text
renderType = send . RenderType
