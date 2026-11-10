-- | Stored structure, independent of any historical executable contract.
module Kyyn.Domain.StoredSnapshot
  ( StoredSnapshot(..), RecordedValue(..), RecordedRecipe(..), storageShape, inferredShape ) where

import Data.Aeson (Value)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Types.StoredShape (StoredShape(..), canonicalShape)
import Kyyn.Domain.Recipe (RecipeDefinition)
import Kyyn.Types.Fact (Fact)

-- Values carry their inferred storage shape, including empty-list/None types.
data RecordedValue = RecordedValue Shape Value deriving (Eq, Show)
data RecordedRecipe = RecordedRecipe RecipeDefinition RecordedValue deriving (Eq, Show)
-- Collections retain membership order. Facts include their complete envelopes.
data StoredSnapshot = StoredSnapshot
  { fields :: [(Text, RecordedValue)]
  , collections :: [(Text, [Fact RecordedValue])]
  , recipes :: [Fact RecordedRecipe]
  } deriving (Eq, Show)

-- Captured storage has only inferred structural scalars, never semantic tags.
storageShape :: Shape -> Either String StoredShape
storageShape = fmap canonicalShape . go
  where
    go shape = case shape of
      Scalar TextScalar -> Right StoredText
      Scalar IntegerScalar -> Right StoredInteger
      Scalar NaturalScalar -> Right StoredNatural
      Scalar BoolScalar -> Right StoredBool
      Record fields -> StoredRecord <$> traverse (\(name,value) -> (Text.pack name,) <$> go value) fields
      Union cases -> StoredUnion <$> traverse (\(name,value) -> (Text.pack name,) <$> traverse go value) cases
      List inner -> StoredList <$> go inner
      Optional inner -> StoredOptional <$> go inner
      _ -> Left "Expected inferred storage shape, not a semantic contract"

inferredShape :: StoredShape -> Shape
inferredShape shape = case canonicalShape shape of
  StoredText -> Scalar TextScalar
  StoredInteger -> Scalar IntegerScalar
  StoredNatural -> Scalar NaturalScalar
  StoredBool -> Scalar BoolScalar
  StoredRecord fields -> Record [(Text.unpack name,inferredShape inner) | (name,inner) <- fields]
  StoredUnion cases -> Union [(Text.unpack name,inferredShape <$> inner) | (name,inner) <- cases]
  StoredList inner -> List (inferredShape inner)
  StoredOptional inner -> Optional (inferredShape inner)
