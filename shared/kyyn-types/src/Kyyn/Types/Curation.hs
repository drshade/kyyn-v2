module Kyyn.Types.Curation
  ( RecipeId(..), EvidenceScope(..), Acknowledgement(..), Curation(..) ) where

import Kyyn.Types.Evidence (EvidenceId)

-- | The name of a recipe declared in the KB manifest.
newtype RecipeId = RecipeId String deriving (Eq, Show)

-- | A connector instance and the particular fetch being acknowledged.
data EvidenceScope = EvidenceScope
  { plugin :: String, instanceName :: String, fetch :: String }
  deriving (Eq, Show)

-- | Declare all evidence in a fetch handled, or only the selected IDs.
-- An ID absent at that fetch acknowledges its deletion.
data Acknowledgement
  = EntireBatch EvidenceScope
  | IndividualRecords EvidenceScope [EvidenceId]
  deriving (Eq, Show)

-- | Evidence handled for one recipe, in declaration order.
data Curation = Curation RecipeId [Acknowledgement] deriving (Eq, Show)
