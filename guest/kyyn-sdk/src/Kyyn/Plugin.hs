module Kyyn.Plugin
  ( SourceConnector(..), CapturedMethod(..), Program, EvidenceSnapshot, FetchError(..), EvidenceId(..), EvidenceFingerprint(..)
  , Evidence(..), EvidenceChange(..), CapturedText(..) ) where

import Kyyn.Types.Program (Program)
import Kyyn.Types.Plugin (SourceConnector(..), CapturedMethod(..), EvidenceSnapshot, FetchError(..), CapturedText(..))
import Kyyn.Types.Evidence (EvidenceId(..), EvidenceFingerprint(..), Evidence(..), EvidenceChange(..))
