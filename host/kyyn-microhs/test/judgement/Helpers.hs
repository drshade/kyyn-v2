{-# LANGUAGE OverloadedStrings, TypeApplications #-}
module Helpers where

import qualified Agentic as A
import Agentic.Contract (Options(..), Option(..), OptionSet(..))
import Agentic.Questions
import Control.Arrow ((>>>), arr)
import Control.Monad.Trans.Except (throwE)
import qualified Data.Text as Text
import Kyyn.Agentic (Flow, interpret, liftTool)
import Kyyn.Connectors (Tool)
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_fixture.Folder as Folder
import Kyyn.Plugin (FetchError)
import qualified Kyyn.Query as Query

data Priority = Routine | Important | Urgent deriving (Eq,Show)

instance Options Priority where
  options = OptionSet Nothing
    [Option Routine "Routine" (Just "low"), Option Important "Important" (Just "mid"),
     Option Urgent "Urgent" (Just "high")]

assessment :: Flow String String
assessment = A.act (\ident -> liftTool (Folder.content Connectors.documents ident) >>= either throwE pure)
  >>> arr Text.pack
  >>> A.judge ((,,) <$> yesNo "Reply?" <*> choice @Priority "Priority?" <*> score @Priority "Severity?")
  >>> arr (\(YesNo p, Choice winner ps confidence, Score position levels _) ->
    show (winner, basisPoints p, basisPoints confidence, position, map fst ps, map fst levels))

run :: String -> Tool (Either FetchError String)
run = interpret assessment
