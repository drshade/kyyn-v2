module Kyyn.Domain.Inspection
  ( SnapshotInspection(..), EvolutionInspection(..), SourceOrigin(..), SourceChange(..)
  , DeclarationRequest(..), DeclarationInspection(..), ImplementationSource(..) ) where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Kyyn.Domain.Model (ModelConfiguration)
import Kyyn.Domain.Query (QueryDefinition, QueryDescriptor)
import Kyyn.Domain.Tool (ToolDefinition, ToolDescriptor)
import Kyyn.Domain.Recipe (StoredRecipe)
import Kyyn.Domain.Root (Root, RootDefinition)
import Kyyn.Domain.Evolution (EvolutionId)
import Kyyn.Domain.EvolutionReport (EvolutionReport)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.Path (RelativePath)
import Kyyn.Domain.Workspace (WorkspaceManifest)

-- Read-only structural data, not a freshly validated root.
data SnapshotInspection = SnapshotInspection GitRevision (Maybe EvolutionId) Root Value RootDefinition

data SourceChange = SourceChange RelativePath (Maybe ByteString) (Maybe ByteString)
  deriving (Eq, Show)

data SourceOrigin = SavedCapture | LiveWorkspace deriving (Eq, Show)

data EvolutionInspection = EvolutionInspection WorkspaceManifest SourceOrigin (Maybe EvolutionReport) [SourceChange]

-- Requests describe entries; only QueryRequest with an input executes a query.
data DeclarationRequest = QueryRequest String (Maybe Text) | ToolRequest String | RecipeRequest Text

data ImplementationSource = ImplementationSource Text (Maybe Text)

data DeclarationInspection
  = QueryInspection QueryDefinition QueryDescriptor ImplementationSource (Maybe Value)
  | ToolInspection ToolDefinition ToolDescriptor (Maybe ModelConfiguration) ImplementationSource
  | RecipeInspection Text StoredRecipe (Maybe Text)
