module Kyyn.Domain.FactProposal (FactProposal(..), FactProposalStep(..)) where

import Data.Aeson (Value)
import Kyyn.Types.Curation (Curation)
import Kyyn.Types.Evolution (Rationale)

-- | Collection-specific edit values are checked against the selected root contract.
data FactProposalStep = FactProposalStep Rationale [Value] deriving (Eq, Show)
data FactProposal = FactProposal [FactProposalStep] Curation deriving (Eq, Show)
