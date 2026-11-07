{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies, OverloadedStrings #-}
module TodoSchemaV2 where

import GHC.Generics (Generic)
import Data.Text (Text)
import Kyyn.Schema

data Status = Open | Done deriving stock (Eq, Show, Generic) deriving anyclass Contract
data Todo = Todo { title :: Text, status :: Status } deriving stock (Eq, Show, Generic) deriving anyclass Contract
data Root = Root { todos :: [Fact Todo] } deriving stock (Eq, Show, Generic) deriving anyclass Contract

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "todos" "todos" []]
