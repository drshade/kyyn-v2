{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, TypeOperators #-}
module Kyyn.Plugin
  ( SourceConnector(..), CapturedMethod(..), Program, EvidenceSnapshot, FetchError(..), EvidenceId(..), EvidenceFingerprint(..)
  , Evidence(..), EvidenceChange(..), CapturedText(..), CapturedRead, ReadsEvidence, listEvidenceIds, readEvidence ) where

import Kyyn.Types.Program (Program, (:+:)(..), request)
import Kyyn.Types.PluginHost (Http, Secrets, Waiting)
import Kyyn.Types.Plugin (EvidenceRead(..), FileRead)
import Kyyn.Types.Plugin (SourceConnector(..), CapturedMethod(..), EvidenceSnapshot, FetchError(..), CapturedText(..))
import Kyyn.Types.Evidence (EvidenceId(..), EvidenceFingerprint(..), Evidence(..), EvidenceChange(..))

-- | A plugin method that reads captured evidence without acquiring new source data.
type CapturedRead payload = Program (EvidenceRead payload)

-- | Evidence-reading operations shared by acquisition and captured-read programs.
class ReadsEvidence row payload where
  injectEvidence :: EvidenceRead payload a -> row a

instance ReadsEvidence (EvidenceRead payload) payload where
  injectEvidence = id

instance ReadsEvidence (Http :+: (Secrets :+: (Waiting :+: (FileRead :+: EvidenceRead payload)))) payload where
  injectEvidence = InRight . InRight . InRight . InRight

-- | List IDs in the selected captured evidence snapshot.
listEvidenceIds :: ReadsEvidence row payload => EvidenceSnapshot payload -> Program row (Either FetchError [EvidenceId])
listEvidenceIds = request . injectEvidence . ListEvidenceIds

-- | Read one item from the selected captured evidence snapshot.
readEvidence :: ReadsEvidence row payload => EvidenceSnapshot payload -> EvidenceId
  -> Program row (Either FetchError (Maybe (Evidence payload)))
readEvidence snapshot key = request (injectEvidence (ReadEvidence snapshot key))
