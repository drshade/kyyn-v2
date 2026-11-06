{-# LANGUAGE DeriveAnyClass, DerivingStrategies, DeriveGeneric, NoFieldSelectors, OverloadedStrings #-}
module Schema (Root(..), Item(..), metadata, validate) where

import Data.Fixed (Fixed, E2)
import GHC.Generics (Generic)
import Kyyn.Schema
import Kyyn.Types.Diagnostic (ValidationReport(..))

data Item = Item { amount :: Fixed E2 }
  deriving stock (Generic) deriving anyclass (Contract)
data Root = Root { items :: [Fact Item] }
  deriving stock (Generic) deriving anyclass (Contract)

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "items-é" "items" []]

validate :: Root -> ValidationReport
validate _ = ValidationReport []
