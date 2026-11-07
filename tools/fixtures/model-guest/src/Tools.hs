{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies, OverloadedStrings, TypeApplications #-}
module Tools where
import GHC.Generics (Generic)
import Data.Text (Text)
import Agentic.Contract (Contract, Options(..), Option(..), OptionSet(..))
import Agentic.Questions (yesNo, choice, score, YesNo(..), Choice(..), Score(..), basisPoints)
import Control.Arrow ((>>>), arr)
import qualified Data.Text as Text
import qualified Agentic as A
import Kyyn.Agentic (Flow, interpret)
import Kyyn.Connectors (Tool)
import Kyyn.Plugin (FetchError)
data Answer = Answer { message :: Text } deriving stock Generic deriving anyclass Contract
type Input = Text
type Output = Answer
inner :: Flow Text Answer
inner = A.draft "inner"
outer :: Flow Text Answer
outer = A.draftWith [A.tool "helper" "nested draft" inner] "outer"
draft :: Input -> Tool (Either FetchError Output)
draft = interpret outer

data Priority = Routine | Important | Urgent deriving (Eq, Show)
instance Options Priority where
  options = OptionSet Nothing [Option Routine "Routine" (Just "low"), Option Important "Important" (Just "mid"), Option Urgent "Urgent" (Just "high")]
assessment :: Flow Text Text
assessment = A.judge ((,,) <$> yesNo "Reply?" <*> choice @Priority "Priority?" <*> score @Priority "Severity?")
  >>> arr (\(YesNo p, Choice winner ps confidence, Score position levels _) ->
    Text.pack (show (winner, basisPoints p, basisPoints confidence, position, map fst ps, map fst levels)))
assess :: Text -> Tool (Either FetchError Text)
assess = interpret assessment
