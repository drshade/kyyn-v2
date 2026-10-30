{-# LANGUAGE OverloadedStrings #-}
module TranscriptFixture where

import Data.Text (Text)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import Kyyn.Validation
import MicrosoftGraph.Meetings.Types (MeetingArtifact(..), MeetingRef(..))
import qualified MicrosoftGraph.Plugin as Graph

newtype Config = Config { endpoint :: Text }
validate :: Config -> ValidationReport
validate _ = ValidationReport []

-- Keep production Meetings method registration; replace only acquisition/config
-- with a synthetic loopback source so the installed read needs no tenant access.
connectors :: [Connector]
connectors = [SourceConnector kind "TranscriptFixture.capture" "TranscriptFixture.validate" methods Nothing
  | SourceConnector kind _ _ methods _ <- Graph.connectors, kind == "Meetings"]

capture :: Config -> EvidenceSnapshot MeetingArtifact -> Acquisition MeetingArtifact (Either FetchError [EvidenceChange MeetingArtifact])
capture (Config url) _ = do
  downloaded <- storeBlob (BlobDownload (HttpRequest "GET" url [] "") (Just "synthetic.vtt") (Just "text/vtt"))
  pure $ case downloaded of
    Right (BlobResponse 200 _ (Just ref@(BlobRef hash _ _ _))) ->
      let meeting = MeetingRef "synthetic-meeting" "https://fixture.invalid/meeting" "Synthetic meeting" "synthetic-organizer"
          evidence key payload = NewEvidence (EvidenceId key) (Evidence (EvidenceFingerprint hash) [] payload)
      in Right [evidence "transcript" (Available (Transcript meeting "2026-10-14T12:00:00Z" "2026-10-14T12:01:00Z" ref)),
                evidence "attendance" (Available (Attendance meeting "2026-10-14T12:00:00Z" "2026-10-14T12:01:00Z" [])),
                evidence "truncated" Truncated]
    _ -> Left (FetchError "Synthetic transcript download failed")
