module Kyyn.Types.SchemaMetadata where

data Affordance = Title | Timeline | Badge deriving (Eq, Show)

data RoleDecl = RoleDecl String String Affordance deriving (Eq, Show)

data FieldRole = FieldRole String String String deriving (Eq, Show)

data CollectionDecl = CollectionDecl String String [(String, String)] deriving (Eq, Show)

data SchemaMetadata = SchemaMetadata [RoleDecl] [FieldRole] [CollectionDecl] deriving (Eq, Show)
