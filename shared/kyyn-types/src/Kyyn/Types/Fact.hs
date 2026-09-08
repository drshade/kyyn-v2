module Kyyn.Types.Fact (FactId(..), Fact(..)) where

newtype FactId = FactId String deriving (Eq, Show)

data Fact a = Fact { id :: FactId, value :: a } deriving (Eq, Show)
