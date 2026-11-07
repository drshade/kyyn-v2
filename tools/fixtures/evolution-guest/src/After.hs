{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies, NoFieldSelectors #-}
module After (Root(..), Item(..)) where
import qualified Data.Text
import GHC.Generics (Generic)
import Kyyn.Schema (Contract, Fact)
data Root = Root { items :: [Fact Item] } deriving stock (Generic) deriving anyclass (Contract)
data Item = Item { amount :: Integer, note :: Data.Text.Text } deriving stock (Generic) deriving anyclass (Contract)
