{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Composition.Runs (dispatchRuns) where

import Data.Aeson (object, (.=))
import Kyyn.Configuration (Host, SelectedKb(..))
import Kyyn.Composition.Runtime (finish, runBase)
import Kyyn.Domain.Recipe (RecipeId(..))
import Kyyn.Domain.RecipeRun
import Kyyn.Domain.Evolution (evolutionIdName)
import qualified Data.Text as Text
import Kyyn.Porcelain.Capability.RecipeRunStore
import Kyyn.Plumbing.Interpreter.AppendJournal (runAppendJournalIO)
import Kyyn.Porcelain.Interpreter.RecipeRunStore (runRecipeRunStore)
import Kyyn.Plumbing.Protocol.RecipeRun (summaryValue)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Result (Response, success)

dispatchRuns :: Host -> Cli.RunCommand -> SelectedKb -> IO Response
dispatchRuns host command (SelectedKb kb _ _) = finish $ runBase host . runAppendJournalIO . runRecipeRunStore (const (pure ())) $
  case command of
    Cli.ListRuns selected -> do
      runs <- listRecipeRuns kb selected
      pure (success (object ["runs" .= map summaryValue runs])
        (if null runs then ["No recipe runs recorded."] else map describe runs))
    Cli.ShowRun identity -> do
      page <- readRecipeRun kb identity Nothing 0
      pure (success (summaryValue page.summary) ([describe page.summary,
        "Events: " ++ show page.summary.eventCount] ++
        ["Ignoring an incomplete final event; the complete prefix is readable." | page.incompleteTail]))
    Cli.ClearRun identity -> do
      clearRecipeRun kb identity
      pure (success (object ["cleared" .= runIdText identity]) ["Cleared run " ++ runIdText identity])
  where
    describe summary = let RecipeId name = summary.header.recipe in
      runIdText summary.header.runId ++ "  " ++ Text.unpack name ++ "  " ++ Text.unpack summary.header.startedAt ++ "  " ++ status summary.status
    status Active = "active"
    status Interrupted = "interrupted"
    status (Completed draft) = "completed → " ++ evolutionIdName draft
    status Failed = "failed"
    status Cancelled = "cancelled"
