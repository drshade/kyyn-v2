{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.SchemaInspection
  ( SchemaInspection(..), inspectSchema, SchemaSource, schemaSource, schemaSources, selectedType ) where

import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources)
import Kyyn.Plumbing.Capability.SchemaInspection.Metadata (metadataAdapter)

data SchemaSource = SchemaSource String GuestSources deriving (Eq, Show)

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
  InspectSchema :: SchemaSource -> SchemaInspection m (Either [Diagnostic] CheckedContract)

type instance DispatchOf SchemaInspection = Dynamic

inspectSchema :: SchemaInspection :> es => SchemaSource -> Eff es (Either [Diagnostic] CheckedContract)
inspectSchema = send . InspectSchema
