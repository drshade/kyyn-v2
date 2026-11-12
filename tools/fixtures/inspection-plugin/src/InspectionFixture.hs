module InspectionFixture where

import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import Kyyn.Schema (Contract)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import Kyyn.Validation

data Auth = Anonymous | Credential { secretName :: Text }
  deriving stock (Eq, Show, Generic) deriving anyclass Contract
data Config = Config { endpoint :: Text, authentication :: Auth }
  deriving stock Generic deriving anyclass Contract
data Payload = Document { title :: Text, body :: Text, attachment :: BlobRef }
  | Measurement Integer | Empty
  deriving stock Generic deriving anyclass Contract
newtype Options = Options { marker :: Text } deriving stock Generic deriving anyclass Contract
data Report = Report { examined :: Integer, notes :: [Text] }
  deriving stock Generic deriving anyclass Contract

connectors :: [Connector]
connectors = [SourceConnector "Capture" "InspectionFixture.capture" "InspectionFixture.validate" [] Nothing]
validate :: Config -> ValidationReport
validate _ = ValidationReport []

capture :: Config -> Maybe Options -> FetchContext Integer -> EvidenceSnapshot Payload
  -> Acquisition Payload (Either FetchError (FetchResult Payload Integer Report))
capture (Config url _) options (FetchContext _ prior) snapshot = do
  previous <- listEvidenceIds snapshot
  result <- storeBlob (BlobDownload (HttpRequest "GET" url [] "") (Just "fixture.bin") (Just "application/octet-stream"))
  pure $ do
    known <- previous
    case result of
      Right (BlobResponse 200 _ (Just ref@(BlobRef hash _ _ _))) ->
        let change key = if EvidenceId key `elem` known then UpdatedEvidence else NewEvidence
            entry key payload = change key (EvidenceId key) (Evidence (EvidenceFingerprint hash) ["fixture source <reference>"] payload)
        in Right (FetchResult
          [entry "record / one" (Available (Document "Captured <document>" ("First line\nSecond line\n" <> Text.replicate 300 "long mail body ") ref)),
           entry "positional" (Available (Measurement 90)), entry "truncated" Truncated]
          1 (Report 3 ["Fixture coverage", maybe "No position" (const "Continued position") prior, maybe "No options" (\(Options text) -> text) options]))
      _ -> Left (FetchError "Fixture download failed")
