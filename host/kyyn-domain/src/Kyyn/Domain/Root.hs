module Kyyn.Domain.Root (Root(..), RootDefinition(..), CheckedValue(..)) where

import Data.Aeson (Value)
import Kyyn.Domain.Contract (CheckedContract, ContractId)
import Kyyn.Domain.FileTree (FileTree)

data Root = Root { schema :: CheckedContract, facts :: FileTree, code :: FileTree } deriving (Eq, Show)
data RootDefinition = RootDefinition
  { schemaType :: String, schemaMetadata :: String, validator :: String, sources :: FileTree }
  deriving (Eq, Show)
data CheckedValue = CheckedValue ContractId Value deriving (Eq, Show)
