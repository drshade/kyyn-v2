module Kyyn.Types.SchemaMetadata
  ( Affordance(..), RoleDecl(..), FieldRole(..), CollectionDecl(..), SchemaMetadata(..)
  ) where

-- | A host-understood presentation role: a title, timeline value or badge.
data Affordance = Title | Timeline | Badge deriving (Eq, Show)

-- | Declare a role by name, human-readable description and presentation affordance.
data RoleDecl = RoleDecl String String Affordance deriving (Eq, Show)

-- | Assign a named role to a field: record type name, field name, role name.
data FieldRole = FieldRole String String String deriving (Eq, Show)

-- | Describe a collection: logical name, root field, and reference-field/target-collection pairs.
data CollectionDecl = CollectionDecl String String [(String, String)] deriving (Eq, Show)

-- | Schema annotations comprising role declarations, field roles and fact collections.
data SchemaMetadata = SchemaMetadata [RoleDecl] [FieldRole] [CollectionDecl] deriving (Eq, Show)
