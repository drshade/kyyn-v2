{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Meetings.Read (artifact, transcript) where

import Data.Text (Text)
import Kyyn.Plugin
import MicrosoftGraph.Meetings.Types (MeetingArtifact(..))

artifact :: Text -> EvidenceSnapshot MeetingArtifact -> CapturedRead MeetingArtifact (Either FetchError MeetingArtifact)
artifact key snapshot = do
  found <- readEvidence snapshot (EvidenceId key)
  pure $ case found of
    Left problem -> Left problem
    Right Nothing -> Left (FetchError "No captured meeting artifact with that ID")
    Right (Just (Evidence _ _ Truncated)) -> Left (FetchError "Meeting artifact payload has been truncated")
    Right (Just (Evidence _ _ (Available value))) -> Right value

-- | Read captured VTT as UTF-8 without fetching or interpreting its contents.
transcript :: Text -> EvidenceSnapshot MeetingArtifact -> CapturedRead MeetingArtifact (Either FetchError Text)
transcript key snapshot = do
  captured <- artifact key snapshot
  case captured of
    Left problem -> pure (Left problem)
    Right (Transcript _ _ _ content) -> readBlobText content
    Right Attendance {} -> pure (Left (FetchError "Meeting artifact is an attendance report, not a transcript"))
