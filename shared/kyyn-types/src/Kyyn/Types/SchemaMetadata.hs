{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.SchemaMetadata
  ( Affordance(..), RoleDecl(..), FieldRole(..), CollectionDecl(..), SchemaMetadata(..)
  ) where

import Data.Text (Text)
import Data.Aeson (ToJSON, FromJSON)
import GHC.Generics (Generic)

-- | A host-understood presentation role: a title, timeline value or badge.
data Affordance = Title | Timeline | Badge deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | Declare a role by name, human-readable description and presentation affordance.
data RoleDecl = RoleDecl Text Text Affordance deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | Assign a named role to a field: record type name, field name, role name.
data FieldRole = FieldRole Text Text Text deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | Describe a collection: logical name, root field, and reference-field/target-collection pairs.
data CollectionDecl = CollectionDecl Text Text [(Text, Text)] deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | Schema annotations comprising role declarations, field roles and fact collections.
data SchemaMetadata = SchemaMetadata [RoleDecl] [FieldRole] [CollectionDecl] deriving (Eq, Show, Generic, ToJSON, FromJSON)
