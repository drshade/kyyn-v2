module Kyyn.Plugin
  ( SourceConnector(..), AcquisitionContext(..), CapturedMethod(..), Program, EvidenceSnapshot, FetchError(..), EvidenceId(..), EvidenceFingerprint(..)
  , Evidence(..), EvidenceChange(..), CapturedText(..) ) where

import Kyyn.Types.Program (Program)
import Kyyn.Types.Plugin (SourceConnector(..), AcquisitionContext(..), CapturedMethod(..), EvidenceSnapshot, FetchError(..), CapturedText(..))
import Kyyn.Types.Evidence (EvidenceId(..), EvidenceFingerprint(..), Evidence(..), EvidenceChange(..))
