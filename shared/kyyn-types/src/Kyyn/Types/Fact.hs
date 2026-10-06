{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.Fact (FactId(..), Fact(..)) where

import Data.Text (Text)

-- | A fact's identifier, represented as a Text and scoped to its collection.
newtype FactId = FactId Text deriving (Eq, Show)

-- | A fact's identifier paired with its typed payload.
data Fact a = Fact FactId a deriving (Eq, Show)
