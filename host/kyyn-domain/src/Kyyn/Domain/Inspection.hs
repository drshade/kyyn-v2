module Kyyn.Domain.Inspection
  ( SnapshotInspection(..), EvolutionInspection(..), SourceOrigin(..), SourceChange(..) ) where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Evolution (EvolutionId)
import Kyyn.Domain.EvolutionReport (EvolutionReport)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.Path (RelativePath)
import Kyyn.Domain.Workspace (WorkspaceManifest)

-- Read-only structural data, not a freshly validated root.
data SnapshotInspection = SnapshotInspection GitRevision (Maybe EvolutionId) RootContract Value

data SourceChange = SourceChange RelativePath (Maybe ByteString) (Maybe ByteString)
  deriving (Eq, Show)

data SourceOrigin = SavedCapture | LiveWorkspace deriving (Eq, Show)

data EvolutionInspection = EvolutionInspection WorkspaceManifest SourceOrigin (Maybe EvolutionReport) [SourceChange]
