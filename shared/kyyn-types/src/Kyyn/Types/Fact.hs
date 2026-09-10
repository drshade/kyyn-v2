module Kyyn.Types.Fact (FactId(..), Fact(..)) where

-- | A fact's identifier, represented as a String and scoped to its collection.
newtype FactId = FactId String deriving (Eq, Show)

-- | A fact's identifier paired with its typed payload.
data Fact a = Fact FactId a deriving (Eq, Show)
