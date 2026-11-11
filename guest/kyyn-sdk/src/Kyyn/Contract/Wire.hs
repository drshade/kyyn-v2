module Kyyn.Contract.Wire (toWire, fromWire, checkedToWire) where

import qualified Agentic.Value as A
import Agentic.Aeson (toAeson, fromAeson)
import Data.Aeson (Value)
import Data.List (nub)

toWire :: A.Value -> Value
toWire = either error id . checkedToWire

fromWire :: Value -> A.Value
fromWire = fromAeson

-- Check association lists before KeyMap construction can discard duplicate keys,
-- and floating-point values before converting them to Scientific.
checkedToWire :: A.Value -> Either String Value
checkedToWire value = check value >> pure (toAeson value)
  where
    check (A.Number n)
      | isNaN n || isInfinite n = Left "Expected finite model number"
    check (A.Array values) = mapM_ check values
    check (A.Object values)
      | length names /= length (nub names) = Left "duplicate object keys"
      | otherwise = mapM_ (check . snd) values
      where names = map fst values
    check _ = Right ()
