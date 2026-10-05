module Kyyn.Domain.Recipe (DescriptionFormat(..)) where

data DescriptionFormat = Tree | Dot | Mermaid deriving (Eq, Show)
