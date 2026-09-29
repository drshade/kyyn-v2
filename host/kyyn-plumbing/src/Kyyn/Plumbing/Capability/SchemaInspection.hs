{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.SchemaInspection
  ( SchemaInspection(..), InspectedSchema(..), inspectSchema, inspectType, inspectPluginFunction, SchemaSource, schemaSource, schemaSources, selectedType ) where

import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Plugin (QualifiedTypeName, PluginEntryKind, PluginSignature)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources)
import Kyyn.Plumbing.Capability.SchemaInspection.Metadata (metadataAdapter)

data SchemaSource = SchemaSource String GuestSources deriving (Eq, Show)

data InspectedSchema = InspectedSchema
  { contract :: CheckedContract, loadedSources :: [RelativePath] } deriving (Eq, Show)

schemaSource :: [(RelativePath, ByteString)] -> String -> String -> Either String SchemaSource
schemaSource files typeName metadataName = do
  adapter <- metadataAdapter metadataName
  path <- relativePath "KyynMetadataEntry.hs"
  sources <- guestSources path ((path, Text.encodeUtf8 (Text.pack adapter)) : files)
  pure (SchemaSource typeName sources)

schemaSources :: SchemaSource -> GuestSources
schemaSources (SchemaSource _ sources) = sources

selectedType :: SchemaSource -> String
selectedType (SchemaSource name _) = name

data SchemaInspection :: Effect where
  InspectSchema :: SchemaSource -> SchemaInspection m (Either [Diagnostic] InspectedSchema)
  InspectType :: FileTree -> QualifiedTypeName -> SchemaInspection m (Either [Diagnostic] InspectedSchema)
  InspectPluginFunction :: FileTree -> PluginEntryKind -> String -> SchemaInspection m (Either [Diagnostic] PluginSignature)

type instance DispatchOf SchemaInspection = Dynamic

inspectSchema :: SchemaInspection :> es => SchemaSource -> Eff es (Either [Diagnostic] InspectedSchema)
inspectSchema = send . InspectSchema

inspectType :: SchemaInspection :> es => FileTree -> QualifiedTypeName -> Eff es (Either [Diagnostic] InspectedSchema)
inspectType sources = send . InspectType sources

inspectPluginFunction :: SchemaInspection :> es => FileTree -> PluginEntryKind -> String -> Eff es (Either [Diagnostic] PluginSignature)
inspectPluginFunction sources kind = send . InspectPluginFunction sources kind
