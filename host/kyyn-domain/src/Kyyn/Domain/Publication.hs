module Kyyn.Domain.Publication
  ( AcceptanceResult(..), AcceptanceProblem(..), WorkingTreeOutcome(..), CheckoutRecovery(..) ) where

import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionId)
import Kyyn.Domain.Git (GitRevision, LocalBranch)
import Kyyn.Domain.Path (RelativePath)
import Kyyn.Domain.Workspace (EvolutionState)

data AcceptanceResult
  = NotAccepted AcceptanceProblem
  | AcceptedCommit GitRevision WorkingTreeOutcome
  | AlreadyAccepted GitRevision Diagnostic
  deriving (Eq, Show)

data AcceptanceProblem
  = BaseMismatch GitRevision (Maybe GitRevision)
  | NotReady EvolutionState
  | CheckoutMismatch LocalBranch (Maybe LocalBranch)
  | WorkspaceChanged EvolutionId
  | OverlappingEdits [RelativePath]
  | InvalidMaterial [Diagnostic]
  deriving (Eq, Show)

data WorkingTreeOutcome
  = WorkingTreeUpdated
  | WorkingTreeUpdateIncomplete [Diagnostic]
  deriving (Eq, Show)

data CheckoutRecovery = CheckoutRecovery
  { acceptingCommit :: GitRevision, checkoutRevision :: GitRevision, outcome :: WorkingTreeOutcome }
  deriving (Eq, Show)
