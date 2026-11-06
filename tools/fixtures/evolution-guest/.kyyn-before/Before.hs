{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies, NoFieldSelectors #-}
module Before (Root(..), Item(..)) where
import GHC.Generics (Generic)
import Kyyn.Schema (Contract, Fact)
data Root = Root { items :: [Fact Item] } deriving stock (Generic) deriving anyclass (Contract)
data Item = Item { amount :: Integer } deriving stock (Generic) deriving anyclass (Contract)
