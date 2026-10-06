module Kyyn.Runtime.Probability (probabilityCodec, modelProbabilityCodec, probabilitySchema) where

import qualified Agentic.Contract as A
import Agentic.Questions (Probability, basisPoints, fromBasisPoints)
import Agentic.Schema (Schema)
import qualified Agentic.Value as A
import qualified Data.Text as Text
import Kyyn.Runtime.Json
import Text.JSON.Types (JSValue(..))

-- | Exact basis points on the guest wire; reject invalid input before clamping.
probabilityCodec :: Codec Probability
probabilityCodec = Codec (encodeWith integerCodec . toInteger . basisPoints) $ \value -> do
  n <- decodeWith integerCodec value
  if n >= 0 && n <= 10000 then Right (fromBasisPoints (fromInteger n))
    else Left "Expected probability basis points in 0..10000"

probabilitySchema :: Schema
probabilitySchema = let A.Codec schema _ _ = upstream in schema

upstream :: A.Codec Probability
upstream = A.contract

-- | Numeric model values use the upstream Probability contract, not stored units.
modelProbabilityCodec :: Codec Probability
modelProbabilityCodec = Codec encode decode
  where
    A.Codec _ encodeProbability decodeProbability = upstream
    encode p = case encodeProbability p of
      A.Number n -> JSRational False (toRational n)
      _ -> error "Upstream Probability codec did not encode a number"
    decode (JSRational _ r)
      | isNaN n || isInfinite n = Left "Expected finite probability"
      | otherwise = either (Left . Text.unpack) Right (decodeProbability (A.Number n))
      where n = fromRational r
    decode _ = Left "Expected numeric model probability"
