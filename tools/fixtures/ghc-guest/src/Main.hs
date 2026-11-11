module Main (Root(..), Item(..), validate) where

import Data.Fixed (Fixed, E2)
import GHC.Generics (Generic)
import LanguageDefaults (languageWorks)
import Kyyn.Schema
import Kyyn.Types.Diagnostic (ValidationReport(..))

data Item = Item { amount :: Fixed E2 }
  deriving stock (Generic) deriving anyclass (Contract)
data Root = Root { items :: [Fact Item] }
  deriving stock (Generic) deriving anyclass (Contract)

validate :: Root -> ValidationReport
validate _
  | languageWorks = ValidationReport []
  | otherwise = error "Guest language defaults did not execute as expected"
