{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies #-}
module Schema where

import Kyyn.Schema
import GHC.Generics (Generic)

data Root = Root deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] []
