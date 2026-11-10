-- | Stored structure, independent of any historical executable contract.
module Kyyn.Domain.StoredSnapshot
  ( StoredSnapshot(..), RecordedValue(..), RecordedRecipe(..) ) where

import Data.Aeson (Value)
import Data.Text (Text)
import Kyyn.Domain.DataType (Shape)
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
