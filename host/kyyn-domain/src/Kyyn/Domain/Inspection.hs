{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.Inspection
  ( SnapshotInspection(..), EvolutionInspection(..), SourceOrigin(..), SourceChange(..)
  , DeclarationRequest(..), DeclarationInspection(..), ImplementationSource(..)
  , ConfigurationInspection(..), ConnectorDeclarationInspection(..), CatalogueInspection(..)
  , ConnectorInspection(..), EvidenceItemInspection(..), LocalInspection(..) ) where

import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence (Evidence, EvidenceId)
import Kyyn.Domain.EvidenceIndex (EvidenceIndex)
import Kyyn.Domain.Plugin (PluginName, PackageIdentity, ConnectorName, ConnectorTypeName, BindingName, PluginOrigin, MethodName)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Domain.Output (OutputDefinition)
import Kyyn.Domain.Blob (BlobRef)
import Kyyn.Types.Evidence (EvidenceRef)
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
data DeclarationRequest = QueryRequest String (Maybe Text) | ToolRequest String | RecipeRequest Text | PluginRequest Text | OutputRequest String

data ImplementationSource = ImplementationSource Text (Maybe Text)

data DeclarationInspection
  = QueryInspection QueryDefinition QueryDescriptor ImplementationSource (Maybe Value)
  | ToolInspection ToolDefinition ToolDescriptor (Maybe ModelConfiguration) ImplementationSource
  | RecipeInspection Text StoredRecipe (Maybe Text)
  | PluginInspection PluginName PackageIdentity PluginOrigin [ConnectorDeclarationInspection]
  | OutputInspection OutputDefinition QueryDescriptor

data ConnectorInspection = ConnectorInspection
  { plugin :: PluginName, package :: PackageIdentity, name :: ConnectorName
  , binding :: BindingName, kind :: ConnectorTypeName
  , configurationContract :: CheckedContract, configuration :: CheckedValue
  , payloadContract :: CheckedContract
  , capture :: Either [Diagnostic] EvidenceIndex
  }

data EvidenceItemInspection = EvidenceItemInspection EvidenceId (Evidence CheckedValue) [BlobRef]

data LocalInspection = LocalInspection
  (Either [Diagnostic] [ConnectorInspection]) (Maybe EvidenceItemInspection)
  [(EvidenceRef, Either [Diagnostic] ())]

-- Snapshot configuration and machine-local discovery are deliberately separate.
data ConfigurationInspection = ConfigurationInspection [(PluginName, PluginOrigin)]
data CatalogueInspection = CatalogueInspection
  (Either [Diagnostic] ConfigurationInspection)
data ConnectorDeclarationInspection = ConnectorDeclarationInspection
  ConnectorTypeName Bool [(String, CheckedContract)] [(MethodName, String)]
  [(ConnectorName, BindingName, CheckedValue)]
