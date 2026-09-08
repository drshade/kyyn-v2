{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootPublication
  ( RootPublication(..), acceptEvolution, findAcceptanceOnBranch, recoverAcceptedEvolution, alreadyAccepted ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution (Candidate, EvolutionWorkspace)
import Kyyn.Domain.Git (LocalBranch, CommitMetadata, GitRevision)
import Kyyn.Domain.Publication (AcceptanceResult(..), CheckoutRecovery)
import Kyyn.Domain.Root (Root)
import Kyyn.Porcelain.Validated (Validated)

data RootPublication :: Effect where
  FindAcceptanceOnBranch :: LocalBranch -> EvolutionWorkspace
    -> RootPublication m (Either [Diagnostic] (Maybe GitRevision))
  AcceptEvolution :: LocalBranch -> CommitMetadata -> Candidate (Validated Root)
    -> RootPublication m AcceptanceResult
  RecoverAcceptedEvolution :: LocalBranch -> EvolutionWorkspace
    -> RootPublication m (Either [Diagnostic] (Maybe CheckoutRecovery))

type instance DispatchOf RootPublication = Dynamic

findAcceptanceOnBranch :: RootPublication :> es => LocalBranch -> EvolutionWorkspace
  -> Eff es (Either [Diagnostic] (Maybe GitRevision))
findAcceptanceOnBranch branch = send . FindAcceptanceOnBranch branch

acceptEvolution :: RootPublication :> es => LocalBranch -> CommitMetadata -> Candidate (Validated Root)
  -> Eff es AcceptanceResult
acceptEvolution branch metadata = send . AcceptEvolution branch metadata

recoverAcceptedEvolution :: RootPublication :> es => LocalBranch -> EvolutionWorkspace
  -> Eff es (Either [Diagnostic] (Maybe CheckoutRecovery))
recoverAcceptedEvolution branch = send . RecoverAcceptedEvolution branch

alreadyAccepted :: GitRevision -> AcceptanceResult
alreadyAccepted revision = AlreadyAccepted revision (errorDiagnostic "acceptance.already-accepted"
  "This evolution is already accepted; inspect the checkout and explicitly synchronize it if needed")
