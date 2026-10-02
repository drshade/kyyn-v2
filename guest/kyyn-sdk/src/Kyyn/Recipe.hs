{-# LANGUAGE NoFieldSelectors #-}
module Kyyn.Recipe
  ( RecipeInput(..), PendingEvidence(..), PendingChange(..)
  , RecipeId(..), EvidenceScope(..), EvidenceId(..)
  , Curation(..), Acknowledgement(..)
  , ProposedCuration(..), ProposedStep(..), FactEdit(..)
  ) where

import Kyyn.Types.Curation
import Kyyn.Types.Evidence (EvidenceId(..))
import Kyyn.Evolution.Proposal

-- | The selected root and captured pending evidence supplied to a recipe flow.
data RecipeInput root = RecipeInput
  { recipe :: RecipeId, root :: root, pending :: [PendingEvidence] }
  deriving (Eq, Show)

-- | Pending changes for one captured connector instance. Use its scope in curation.
data PendingEvidence = PendingEvidence
  { scope :: EvidenceScope, changes :: [PendingChange] }
  deriving (Eq, Show)

-- | Net changes since this recipe last acknowledged an evidence item.
data PendingChange = New EvidenceId | Updated EvidenceId | Removed EvidenceId
  deriving (Eq, Show)
