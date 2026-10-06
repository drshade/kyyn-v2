{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.Curation
  ( RecipeId(..), EvidenceScope(..), Acknowledgement(..), Curation(..) ) where

import Data.Text (Text)

import Kyyn.Types.Evidence (EvidenceId)

-- | The name of an identified recipe in the selected root.
newtype RecipeId = RecipeId Text deriving (Eq, Show)

-- | A connector instance and the particular fetch being acknowledged.
data EvidenceScope = EvidenceScope
  { scopePlugin :: Text, scopeInstance :: Text, scopeFetch :: Text }
  deriving (Eq, Show)

-- | Declare all evidence in a fetch handled, or only the selected IDs.
-- An ID absent at that fetch acknowledges its deletion.
data Acknowledgement
  = EntireBatch EvidenceScope
  | IndividualRecords EvidenceScope [EvidenceId]
  deriving (Eq, Show)

-- | Evidence handled for one recipe, in declaration order.
data Curation = Curation RecipeId [Acknowledgement] deriving (Eq, Show)
