module Kyyn.Types.Fact (FactId(..), Fact(..)) where

newtype FactId = FactId String deriving (Eq, Show)

data Fact a = Fact FactId a deriving (Eq, Show)
