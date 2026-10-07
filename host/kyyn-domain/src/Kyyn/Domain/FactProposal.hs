module Kyyn.Domain.FactProposal (FactProposal(..), FactProposalStep(..)) where

import Data.Aeson (Value)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Types.Evolution (Rationale)

-- | Collection-specific edit values are checked against the selected root contract.
data FactProposalStep = FactProposalStep Rationale [Value] deriving (Eq, Show)
data FactProposal = FactProposal [FactProposalStep] CheckedValue deriving (Eq, Show)
