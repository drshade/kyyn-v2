module Kyyn.Domain.Example (Example(..), ExampleRequirement(..)) where

import Kyyn.Domain.Query (QueryDescriptor)
import Kyyn.Domain.Value (CheckedValue)

data ExampleRequirement = Required | Illustrative deriving (Eq, Show)

data Example = Example
  { name :: String, query :: QueryDescriptor, arguments :: CheckedValue
  , expected :: CheckedValue, requirement :: ExampleRequirement, explanation :: String
  } deriving (Eq, Show)
