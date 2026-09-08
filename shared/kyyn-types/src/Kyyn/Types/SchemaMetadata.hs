module Kyyn.Types.SchemaMetadata where

data Affordance = Title | Timeline | Badge deriving (Eq, Show)

data RoleDecl = RoleDecl
  { name :: String
  , description :: String
  , affordance :: Affordance
  } deriving (Eq, Show)

data FieldRole = FieldRole
  { recordType :: String
  , field :: String
  , role :: String
  } deriving (Eq, Show)

data CollectionDecl = CollectionDecl
  { collection :: String
  , rootField :: String
  , references :: [(String, String)]
  } deriving (Eq, Show)

data SchemaMetadata = SchemaMetadata
  { roles :: [RoleDecl]
  , fieldRoles :: [FieldRole]
  , collections :: [CollectionDecl]
  } deriving (Eq, Show)
