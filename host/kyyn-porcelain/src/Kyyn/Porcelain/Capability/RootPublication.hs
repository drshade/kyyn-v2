{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootPublication
  ( RootPublication(..), acceptEvolution ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Evolution (Candidate)
import Kyyn.Domain.Git (LocalBranch, CommitMetadata)
import Kyyn.Domain.Publication (AcceptanceResult)
import Kyyn.Domain.Root (Root)
import Kyyn.Porcelain.Validated (Validated)

data RootPublication :: Effect where
  AcceptEvolution :: LocalBranch -> CommitMetadata -> Candidate (Validated Root)
    -> RootPublication m AcceptanceResult

type instance DispatchOf RootPublication = Dynamic

acceptEvolution :: RootPublication :> es => LocalBranch -> CommitMetadata -> Candidate (Validated Root)
  -> Eff es AcceptanceResult
acceptEvolution branch metadata = send . AcceptEvolution branch metadata
