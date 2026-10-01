{-# LANGUAGE NoFieldSelectors #-}
module Kyyn.Evolution.Proposal
  ( FactEdit(..), ProposedStep(..), ProposedCuration(..), applyFactEdit ) where

import Kyyn.Edit (CollectionEdit, append, update, put, remove)
import Kyyn.Types.Fact (Fact, FactId)
import Kyyn.Types.Evolution (Rationale)
import Kyyn.Types.Curation (Curation)

-- | A description of a fact change, not an executable update function.
data FactEdit a
  = Append (Fact a)
  | Replace { factId :: FactId, replacement :: a }
  | Remove FactId
  deriving (Eq, Show)

-- | Ordered changes sharing one explanation and its evidence citations.
data ProposedStep edits = ProposedStep Rationale [edits] deriving (Eq, Show)

-- | Fact-edit steps and an explicit declaration of handled evidence.
data ProposedCuration edits = ProposedCuration [ProposedStep edits] Curation deriving (Eq, Show)

-- | Apply a description using the normal collection ID checks.
applyFactEdit :: FactEdit a -> CollectionEdit a ()
applyFactEdit (Append fact) = append fact
applyFactEdit (Replace key value) = update key (put value)
applyFactEdit (Remove key) = remove key
