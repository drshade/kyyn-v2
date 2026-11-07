{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.Fact (FactId(..), Fact(..), parseFactId, factIdText) where

import Agentic.Contract
import Data.Text (Text)
import qualified Data.Text as Text
import Type.Reflection (Typeable)
import Kyyn.Types.Scalar (textual)

-- | A fact's identifier, represented as a Text and scoped to its collection.
newtype FactId = FactId Text deriving (Eq, Show)

-- | A fact's identifier paired with its typed payload.
data Fact a = Fact FactId a deriving (Eq, Show)

parseFactId :: Text -> Either Text FactId
parseFactId value
  | Text.null value = Left "fact ID must not be empty"
  | otherwise = Right (FactId value)

factIdText :: Codec FactId
factIdText = textual (\(FactId value) -> value) parseFactId

instance Contract FactId where
  contract = scalar (ScalarInfo "Kyyn.FactId" []) (Just factIdText)
instance (Typeable a, Contract a) => Contract (Fact a) where
  contract = nominal $ record "" $
    Fact <$> required "id" "" (\(Fact x _) -> x) <*> required "value" "" (\(Fact _ x) -> x)
