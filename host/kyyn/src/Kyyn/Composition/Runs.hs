{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Composition.Runs (dispatchRuns) where

import Data.Aeson (object, (.=))
import Kyyn.Configuration (Host, SelectedKb(..))
import Kyyn.Composition.Runtime (finish, runBase)
import Kyyn.Domain.Recipe (RecipeId(..))
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Plumbing.Protocol.Validation (diagnosticValue)
import Kyyn.Domain.RecipeRun
import Kyyn.Domain.Evolution (evolutionIdName)
import qualified Data.Text as Text
import Kyyn.Porcelain.Capability.RecipeRunStore
import Kyyn.Plumbing.Interpreter.AppendJournal (runAppendJournalIO)
import Kyyn.Porcelain.Interpreter.RecipeRunStore (runRecipeRunStore)
import Kyyn.Plumbing.Protocol.RecipeRun (summaryValue, listValue)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Result (Response, success)

dispatchRuns :: Host -> Cli.RunCommand -> SelectedKb -> IO Response
dispatchRuns host command (SelectedKb kb _ _) = finish $ runBase host . runAppendJournalIO . runRecipeRunStore (const (pure ())) $
  case command of
    Cli.ListRuns selected -> do
      listing <- listRecipeRuns kb selected
      pure (success (object ["runs" .= map listValue listing.runs,"unavailable" .= map diagnosticValue listing.unavailable])
        ((if null listing.runs then [if null listing.unavailable then "No recipe runs recorded." else "No readable recipe runs recorded."] else map describe listing.runs) ++
          ["Recording unavailable: " ++ Text.unpack problem.message | problem <- listing.unavailable]))
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
    status (Suspended count) = "suspended · waiting on " ++ show count ++ (if count == 1 then " reply" else " replies")
    status Returned = "returned"
