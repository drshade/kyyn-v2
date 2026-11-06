{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies, NoFieldSelectors #-}
module EditProvider (Root, initial, appendOne, count) where

import GHC.Generics (Generic)
import Agentic.Contract (Contract)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Evolution.Proposal (FactEdit(..))
import qualified Data.Text as Text

data Hidden = Hidden { amount :: Integer }
  deriving stock (Generic) deriving anyclass (Contract)
data RootOf a = RootOf { items :: [Fact a] }
  deriving stock (Generic)
type Root = RootOf Hidden
initial :: Root
initial = RootOf []
appendOne :: FactEdit Hidden
appendOne = Append (Fact (FactId (Text.pack "one")) (Hidden 2))
count :: Root -> Int
count (RootOf facts) = length facts
