{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.DhallHandling
  ( DhallHandling(..), decodeValue, encodeValue
  , CheckedDhallValue(..), valueContract, wireValue ) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Plumbing.Capability.SchemaInspection.Contract (CheckedContract, ContractId)

data CheckedDhallValue = CheckedDhallValue ContractId Value deriving (Eq, Show)

valueContract :: CheckedDhallValue -> ContractId
valueContract (CheckedDhallValue identity _) = identity

wireValue :: CheckedDhallValue -> Value
wireValue (CheckedDhallValue _ value) = value

data DhallHandling :: Effect where
  DecodeValue :: CheckedContract -> Text -> DhallHandling m (Either [Diagnostic] CheckedDhallValue)
  EncodeValue :: CheckedContract -> Value -> DhallHandling m (Either [Diagnostic] Text)

type instance DispatchOf DhallHandling = Dynamic

decodeValue :: DhallHandling :> es => CheckedContract -> Text -> Eff es (Either [Diagnostic] CheckedDhallValue)
decodeValue contract = send . DecodeValue contract

encodeValue :: DhallHandling :> es => CheckedContract -> Value -> Eff es (Either [Diagnostic] Text)
encodeValue contract = send . EncodeValue contract
