{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.Query (QueryDefinition(..), QueryDescriptor(..), QueryResult(..)) where

import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Types.Query (ReadAccess)

data QueryDefinition = QueryDefinition
  { name :: String, description :: String, implementation :: String
  , inputType :: String, inputMetadata :: String
  , resultType :: String, resultMetadata :: String
  } deriving (Eq, Show)

data QueryDescriptor = QueryDescriptor
  { name :: String, description :: String
  , inputContract :: CheckedContract, resultContract :: CheckedContract
  } deriving (Eq, Show)

data QueryResult = QueryResult CheckedValue [ReadAccess] deriving (Eq, Show)
