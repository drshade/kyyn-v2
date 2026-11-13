{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Composition.RunViewing (viewRun) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Data.Text (Text)
import qualified Data.Text as Text
import Numeric.Natural (Natural)
import Kyyn.Configuration (Host, SelectedKb(..), selectKnowledgeBase)
import Kyyn.Composition.Runtime (runBase)
import Kyyn.Domain.Path (DirectoryScope, relativePath)
import Kyyn.Domain.KnowledgeBase (knowledgeBaseScope)
import Kyyn.Domain.Recipe (recipeId)
import Kyyn.Domain.RecipeRun (RecipeRunPage(..), recipeRunId, runIdText)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Plumbing.Capability.FileSystem (entryExists)
import Kyyn.Plumbing.Interpreter.AppendJournal (runAppendJournalIO)
import Kyyn.Plumbing.Protocol.RecipeRun (pageValue)
import Kyyn.Porcelain.Capability.RecipeRunStore
import Kyyn.Porcelain.Interpreter.RecipeRunStore (runRecipeRunStore)
import Kyyn.Surfaces.Result (Response, refusal, operationalFailure)
import Kyyn.Web.Runs

viewRun :: Host -> DirectoryScope -> [Text] -> [(Bytes.ByteString, Maybe Bytes.ByteString)]
  -> IO (Either Response RunContent)
viewRun host scope route query = do
  selection <- selectKnowledgeBase host scope
  case selection of
    Left problem -> pure (Left problem)
    Right (SelectedKb kb _ _) -> do
      let execute = runBase host . runAppendJournalIO . runRecipeRunStore (const (pure ()))
      result <- execute $ runExceptT $ do
        let checked = either (throwE . refusal . pure . errorDiagnostic "run.request") pure
            optional name parse = case [value | (key,value) <- query, key == name] of
              [] -> pure Nothing
              [Just value] -> Just <$> checked (parse (Char8.unpack value))
              _ -> throwE (refusal [errorDiagnostic "run.request" "Query parameters must occur once with a value"])
        case route of
          ["runs"] -> do
            selected <- optional "recipe" recipeId
            RunHtml . runIndex selected <$> ExceptT (Right <$> listRecipeRuns kb selected)
          "runs":name:rest | rest == [] || rest == ["events"] -> do
            identity <- checked (recipeRunId (Text.unpack name))
            kbScope <- checked (knowledgeBaseScope kb)
            file <- checked (relativePath (".kyyn/runs/" ++ runIdText identity ++ "/header.json"))
            present <- ExceptT (Right <$> entryExists kbScope file)
            if present then pure () else throwE (refusal [errorDiagnostic "run.unknown" "This recording does not exist or has been cleared"])
            after <- optional "after" canonicalNatural
            limit <- maybe 200 id <$> optional "limit" canonicalNatural
            if limit >= 1 && limit <= 1000 then pure () else throwE (refusal [errorDiagnostic "run.request" "limit must be between 1 and 1000"])
            page <- ExceptT (Right <$> readRecipeRun kb identity after (if null rest then 0 else limit))
            pure (if null rest then RunHtml (runPage page.summary) else RunJson (pageValue page))
          _ -> throwE (refusal [errorDiagnostic "run.unknown" "Unknown run route"])
      case result of
        Right value -> pure value
        Left problem -> do
          -- Clearing may race a page read. Distinguish that disappearance from
          -- a corrupt recording or another IO error, without parsing error text.
          gone <- case route of
            "runs":name:_ -> case (knowledgeBaseScope kb, relativePath (".kyyn/runs/" ++ Text.unpack name ++ "/header.json")) of
              (Right kbScope,Right file) -> runBase host (entryExists kbScope file)
              _ -> pure (Right True)
            _ -> pure (Right True)
          pure (Left (case gone of
            Right False -> refusal [errorDiagnostic "run.unknown" "This recording has been cleared"]
            _ -> operationalFailure problem))

canonicalNatural :: String -> Either String Natural
canonicalNatural value = case reads value of
  [(n,"")] | n >= (0 :: Integer), show n == value -> Right (fromInteger n)
  _ -> Left "Expected a canonical nonnegative integer"
