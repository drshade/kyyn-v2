module Kyyn.Domain.Root (Root(..), RootDefinition(..), CheckedValue(..)) where

import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Query (QueryDefinition)
import Kyyn.Domain.Value (CheckedValue(..))

data Root = Root { schema :: RootContract, facts :: FileTree, code :: FileTree } deriving (Eq, Show)
data RootDefinition = RootDefinition
  { schemaType :: String, schemaMetadata :: String, validator :: String
  , queries :: [QueryDefinition], sources :: FileTree }
  deriving (Eq, Show)
