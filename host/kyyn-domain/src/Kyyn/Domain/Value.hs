module Kyyn.Domain.Value (CheckedValue(..)) where

import Data.Aeson (Value)
import Kyyn.Domain.Contract (ContractId)

data CheckedValue = CheckedValue ContractId Value deriving (Eq, Show)
