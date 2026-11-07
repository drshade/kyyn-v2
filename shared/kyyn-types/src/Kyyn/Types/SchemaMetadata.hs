{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.SchemaMetadata
  ( Affordance(..), RoleDecl(..), FieldRole(..), CollectionDecl(..), SchemaMetadata(..)
  ) where

import Data.Text (Text)
import Data.Aeson (ToJSON(..), FromJSON(..), Value, object, (.=), (.:))
import Data.Aeson.Types (Parser)
import Kyyn.Types.Json (exactObject)

-- | A host-understood presentation role: a title, timeline value or badge.
data Affordance = Title | Timeline | Badge deriving (Eq, Show)

-- | Declare a role by name, human-readable description and presentation affordance.
data RoleDecl = RoleDecl Text Text Affordance deriving (Eq, Show)

-- | Assign a named role to a field: record type name, field name, role name.
data FieldRole = FieldRole Text Text Text deriving (Eq, Show)

-- | Describe a collection: logical name, root field, and reference-field/target-collection pairs.
data CollectionDecl = CollectionDecl Text Text [(Text, Text)] deriving (Eq, Show)

-- | Schema annotations comprising role declarations, field roles and fact collections.
data SchemaMetadata = SchemaMetadata [RoleDecl] [FieldRole] [CollectionDecl] deriving (Eq, Show)

instance ToJSON SchemaMetadata where
  toJSON (SchemaMetadata roles assignments collections) = object
    ["roles" .= [object ["name" .= name,"description" .= description,
      "affordance" .= object ["tag" .= affordanceName affordance]] | RoleDecl name description affordance <- roles],
     "fields" .= [object ["type" .= record,"field" .= field,"role" .= role] | FieldRole record field role <- assignments],
     "collections" .= [object ["name" .= name,"field" .= field,"references" .=
       [object ["field" .= f,"collection" .= c] | (f,c) <- references]] | CollectionDecl name field references <- collections]]

instance FromJSON SchemaMetadata where
  parseJSON = exactObject "schema metadata" ["roles","fields","collections"] $ \record -> SchemaMetadata
    <$> (record .: "roles" >>= traverse (exactObject "role" ["name","description","affordance"] (\role -> RoleDecl
      <$> role .: "name" <*> role .: "description" <*> (role .: "affordance" >>= parseAffordance))))
    <*> (record .: "fields" >>= traverse (exactObject "field role" ["type","field","role"] (\field -> FieldRole
      <$> field .: "type" <*> field .: "field" <*> field .: "role")))
    <*> (record .: "collections" >>= traverse (exactObject "collection" ["name","field","references"] (\collection -> CollectionDecl
      <$> collection .: "name" <*> collection .: "field"
      <*> (collection .: "references" >>= traverse (exactObject "reference" ["field","collection"] (\ref ->
        (,) <$> ref .: "field" <*> ref .: "collection"))))))

affordanceName :: Affordance -> Text
affordanceName Title = "Title"
affordanceName Timeline = "Timeline"
affordanceName Badge = "Badge"

parseAffordance :: Value -> Parser Affordance
parseAffordance = exactObject "affordance" ["tag"] $ \record -> do
  name <- record .: "tag" :: Parser Text
  case name of
    "Title" -> pure Title
    "Timeline" -> pure Timeline
    "Badge" -> pure Badge
    _ -> fail "Unknown affordance"
