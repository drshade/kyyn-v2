{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedRecordDot, OverloadedStrings, ScopedTypeVariables, TypeApplications #-}
module Kyyn.Porcelain.Interpreter.RecipeRunStore (runRecipeRunStore) where

import Control.Monad (forM, unless, when, void)
import Data.Aeson (encode, eitherDecodeStrict')
import Data.Aeson.Types (parseEither, Parser)
import qualified Data.Aeson as Json
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.List (sortOn)
import Data.Maybe (isJust)
import Data.Ord (Down(..))
import Numeric.Natural (Natural)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import Effectful.Error.Static (catchError)
import Kyyn.Domain.RecipeRun
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase, knowledgeBaseScope)
import Kyyn.Domain.Path (DirectoryScope, scopePath, directoryScope, relativePath, relativeName)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Evolution (evolutionIdName)
import Kyyn.Porcelain.Capability.RecipeRunStore
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.AppendJournal
import Kyyn.Plumbing.Protocol.RecipeRun
import System.FilePath ((</>))

runRecipeRunStore :: (AppendJournal :> es, Failure :> es)
  => (RecipeRunHeader -> Eff es ()) -> Eff (RecipeRunStore : es) a -> Eff es a
runRecipeRunStore announce = interpret $ \env -> \case
  WithRecipeRun prepared use -> localSeqUnlift env $ \unlift -> do
    directory <- baseDirectory prepared.knowledgeBase
    let header (JournalStamp name started) = RecipeRunHeader
          (either error id (recipeRunId (relativeName name))) prepared.recipe prepared.flow prepared.before prepared.build started prepared.graph
        record stamp event = void (writeEvent directory (header stamp) event)
        cleanup stamp exit = record stamp (case exit of
          JournalCancelled -> RunCancelled
          JournalException message -> RunFailed [errorDiagnostic "run.failed" message])
    withJournal directory (Lazy.toStrict . encode . headerValue . header) cleanup $ \stamp -> do
      let h = header stamp
      catchError @Failure.OperationalFailure
        (announce h >> unlift (use (RecipeRunWriter prepared.knowledgeBase h)))
        (\_ problem -> do
          catchError @Failure.OperationalFailure
            (record stamp (RunFailed [errorDiagnostic "run.failed" (show problem)])) (\_ _ -> pure ())
          raiseFailure problem)
  AppendRunEvent (RecipeRunWriter kb header) event -> do
    directory <- baseDirectory kb
    writeEvent directory header event
  ListRecipeRuns kb selected -> do
    directory <- baseDirectory kb
    names <- listJournals directory
    summaries <- forM names $ \name -> do
      identity <- checked (relativeName name) (recipeRunId (relativeName name))
      (.summary) <$> readRun directory identity Nothing 0
    pure (sortOn (Down . (.header.startedAt)) [s | s <- summaries, maybe True (== s.header.recipe) selected])
  ReadRecipeRun kb identity cursor limit -> baseDirectory kb >>= \directory -> readRun directory identity cursor limit
  ClearRecipeRun kb identity -> do
    directory <- baseDirectory kb
    name <- checked (runIdText identity) (relativePath (runIdText identity))
    clearJournal directory name

baseDirectory :: Failure :> es => KnowledgeBase -> Eff es DirectoryScope
baseDirectory kb = checked ".kyyn/runs" $ do
  base <- knowledgeBaseScope kb
  directoryScope (scopePath base </> ".kyyn" </> "runs")
failAt :: Failure :> es => FilePath -> String -> Eff es a
failAt path message = raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.ReadFile path message))
checked :: Failure :> es => FilePath -> Either String a -> Eff es a
checked path = either (failAt path) pure

writeEvent :: (AppendJournal :> es, Failure :> es) => DirectoryScope -> RecipeRunHeader -> RunEventBody -> Eff es RunEvent
writeEvent directory header body = do
  name <- checked (runIdText header.runId) (relativePath (runIdText header.runId))
  elapsed <- catchError @Failure.OperationalFailure
    (appendJournal directory name (isJust (terminalStatus body)) (Lazy.toStrict . encode . eventValue . (`RunEvent` body)))
    (\_ problem -> raiseFailure (case (body,problem) of
      (RunCompleted draft,Failure.StorageUnavailable (Failure.StorageDiagnostic operation path message)) ->
        Failure.StorageUnavailable (Failure.StorageDiagnostic operation path (message ++ "; draft already exists: " ++ evolutionIdName draft))
      _ -> problem))
  pure (RunEvent elapsed body)

readRun :: (AppendJournal :> es, Failure :> es) => DirectoryScope -> RecipeRunId -> Maybe Natural -> Natural -> Eff es RecipeRunPage
readRun directory identity cursor limit = do
  name <- checked (runIdText identity) (relativePath (runIdText identity))
  let path = scopePath directory </> runIdText identity
  JournalSnapshot headerBytes records active partial <- readJournal directory name
  header <- decodeAt (path </> "header.json") parseHeader headerBytes
  unless (header.runId == identity) (failAt path "Header run ID differs from directory")
  events <- forM (zip [0 :: Natural ..] records) $ \(n,line) ->
    decodeAt (path ++ "/events.jsonl line " ++ show (n+1)) parseEvent line
  state <- inspectEvents path events
  let status = case state of Just terminal -> terminal; Nothing -> if active then Active else Interrupted
      allEvents = zipWith SequencedRunEvent [0..] events
      remaining = [item | item@(SequencedRunEvent n _) <- allEvents, maybe True (n >) cursor]
      page = take (fromIntegral (min limit (fromIntegral (maxBound :: Int)))) remaining
      next = case reverse page of SequencedRunEvent n _:_ -> Just n; [] -> cursor
  pure (RecipeRunPage (RecipeRunSummary header status (fromIntegral (length events))) page next
    (length page < length remaining) partial)

inspectEvents :: Failure :> es => FilePath -> [RunEvent] -> Eff es (Maybe RunStatus)
inspectEvents path = go (1 :: Natural) 0 Nothing
  where
    go _ _ terminal [] = pure terminal
    go n elapsed terminal (event:rest) = do
      let location = path ++ "/events.jsonl line " ++ show n
      when (isJust terminal) (failAt location "Event follows terminal")
      when (event.elapsedNanos < elapsed) (failAt location "Elapsed time decreased")
      go (n+1) event.elapsedNanos (terminalStatus event.body) rest

decodeAt :: Failure :> es => FilePath -> (Json.Value -> Parser a) -> Bytes.ByteString -> Eff es a
decodeAt path parser bytes = checked path (eitherDecodeStrict' bytes >>= parseEither parser)
