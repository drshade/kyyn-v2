module Kyyn.Runtime.Probability (probabilityCodec, modelProbabilityCodec, probabilitySchema) where

import qualified Agentic.Contract as A
import Agentic.Questions (Probability, basisPoints, fromBasisPoints)
import Agentic.Schema (Schema)
import qualified Agentic.Value as A
import qualified Data.Text as Text
import Kyyn.Runtime.Json
import Data.Aeson (Value(..))

-- | Exact basis points on the guest wire; reject invalid input before clamping.
probabilityCodec :: Codec Probability
probabilityCodec = Codec (encodeWith integerCodec . toInteger . basisPoints) $ \value -> do
  n <- decodeWith integerCodec value
  if n >= 0 && n <= 10000 then Right (fromBasisPoints (fromInteger n))
    else Left "Expected probability basis points in 0..10000"

probabilitySchema :: Schema
probabilitySchema = let A.Codec schema _ _ = upstream in schema

upstream :: A.Codec Probability
upstream = either (error . show) id (A.compileModel A.contract)

-- | Numeric model values use the upstream Probability contract, not stored units.
modelProbabilityCodec :: Codec Probability
modelProbabilityCodec = Codec encode decode
  where
    A.Codec _ encodeProbability decodeProbability = upstream
    encode p = case encodeProbability p of
      A.Number n -> Number (realToFrac n)
      _ -> error "Upstream Probability codec did not encode a number"
    decode (Number r)
      | isNaN n || isInfinite n = Left "Expected finite probability"
      | otherwise = either (Left . Text.unpack) Right (decodeProbability (A.Number n))
      where n = realToFrac r
    decode _ = Left "Expected numeric model probability"
