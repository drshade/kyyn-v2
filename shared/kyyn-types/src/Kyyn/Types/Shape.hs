module Kyyn.Types.Shape (Shape(..), ScalarKind(..)) where

import qualified Kyyn.Types.Contract.ScalarKind as Contract

data Shape
  = Record [(String, Shape)] | List Shape | Optional Shape
  | Union [(String, Maybe Shape)] | Scalar ScalarKind | Reference String
  deriving (Eq, Show)

data ScalarKind = TextScalar | IntegerScalar | NaturalScalar | BoolScalar | ProbabilityScalar
  | ExactScalar Contract.ScalarKind deriving (Eq, Show)

