module Kyyn.Porcelain.Validation.Types (Validated(..)) where

newtype Validated a = Validated a deriving (Eq, Show)
