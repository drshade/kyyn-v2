{-# LANGUAGE DeriveAnyClass, DeriveGeneric, OverloadedStrings #-}
module Kyyn.Types.Contract.ScalarKind (ScalarKind(..)) where

import Control.DeepSeq (NFData)
import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), withArray)
import Data.Foldable (toList)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Text.Read (readMaybe)

data ScalarKind
  = TextScalar | BoolScalar | IntegerScalar | IntScalar Integer Integer
  | NaturalScalar | DecimalScalar Integer | DateScalar | InstantScalar
  | ProbabilityScalar | FactIdScalar | BlobRefScalar
  deriving (Eq, Show, Generic, NFData)

instance ToJSON ScalarKind where
  toJSON value = toJSON $ case value of
    TextScalar -> ["text"]
    BoolScalar -> ["bool"]
    IntegerScalar -> ["integer"]
    IntScalar lo hi -> ["bounded-integer", T.pack (show lo), T.pack (show hi)]
    NaturalScalar -> ["natural"]
    DecimalScalar resolution -> ["decimal", T.pack (show resolution)]
    DateScalar -> ["date"]
    InstantScalar -> ["instant"]
    ProbabilityScalar -> ["probability"]
    FactIdScalar -> ["fact-id"]
    BlobRefScalar -> ["blob-ref"]

instance FromJSON ScalarKind where
  parseJSON = withArray "scalar descriptor" $ \values -> case toList values of
    [String "text"] -> pure TextScalar
    [String "bool"] -> pure BoolScalar
    [String "integer"] -> pure IntegerScalar
    [String "bounded-integer",String lo,String hi] -> IntScalar <$> number lo <*> number hi
    [String "natural"] -> pure NaturalScalar
    [String "decimal",String resolution] -> DecimalScalar <$> number resolution
    [String "date"] -> pure DateScalar
    [String "instant"] -> pure InstantScalar
    [String "probability"] -> pure ProbabilityScalar
    [String "fact-id"] -> pure FactIdScalar
    [String "blob-ref"] -> pure BlobRefScalar
    _ -> fail "unsupported scalar descriptor"
    where
      number text = case readMaybe (T.unpack text) of
        Just n | T.pack (show (n :: Integer)) == text -> pure n
        _ -> fail "expected a canonical integer in the scalar descriptor"

