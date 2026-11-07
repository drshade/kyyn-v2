{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.SchemaInspection
  ( SchemaInspection(..), InspectedSchema(..), inspectSchema, SchemaSource, schemaSource, schemaSources ) where

import Data.ByteString (ByteString)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Guest (InspectedSchema(..))
import Kyyn.Domain.Path (RelativePath)
import Kyyn.Plumbing.Capability.GuestCompilation.Types

newtype SchemaSource = SchemaSource GuestSources deriving (Eq, Show)

schemaSource :: [(RelativePath, ByteString)] -> Either String SchemaSource
schemaSource sources = SchemaSource <$> guestSources (DiscoveryEntries RootSchema) sources

schemaSources :: SchemaSource -> GuestSources
schemaSources (SchemaSource sources) = sources

data SchemaInspection :: Effect where
  InspectSchema :: SchemaSource -> SchemaInspection m (Either [Diagnostic] InspectedSchema)

type instance DispatchOf SchemaInspection = Dynamic

inspectSchema :: SchemaInspection :> es => SchemaSource -> Eff es (Either [Diagnostic] InspectedSchema)
inspectSchema = send . InspectSchema
