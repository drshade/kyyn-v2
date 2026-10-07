{-# LANGUAGE NoFieldSelectors #-}
module Kyyn.Evolution.Proposal
  ( FactEdit(..), ProposedStep(..), RecipeProposal(..), applyFactEdit ) where

import Kyyn.Edit (CollectionEdit, append, update, put, remove)
import Kyyn.Types.Fact (Fact, FactId)
import Kyyn.Types.Evolution (Rationale)

-- | A description of a fact change, not an executable update function.
data FactEdit a
  = Append (Fact a)
  | Replace { factId :: FactId, replacement :: a }
  | Remove FactId
  deriving (Eq, Show)

-- | Ordered changes sharing one explanation and its evidence citations.
data ProposedStep edits = ProposedStep Rationale [edits] deriving (Eq, Show)

-- | Proposed fact edits and the complete next state of the selected recipe.
data RecipeProposal edits state = RecipeProposal
  { steps :: [ProposedStep edits], state :: state } deriving (Eq, Show)

-- | Apply a description using the normal collection ID checks.
applyFactEdit :: FactEdit a -> CollectionEdit a ()
applyFactEdit (Append fact) = append fact
applyFactEdit (Replace key value) = update key (put value)
applyFactEdit (Remove key) = remove key
