module Kyyn.Porcelain.Validation.Types (Validated(..), validatedValue) where

import Data.Coerce (coerce)

newtype Validated a = Validated a deriving (Eq, Show)

validatedValue :: Validated a -> a
validatedValue = coerce
