{-# LANGUAGE OverloadedStrings #-}
module Blobs.Source where
import Data.Text (Text)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import Kyyn.Validation

newtype Config = Config { endpoint :: Text }
validate :: Config -> ValidationReport
validate _ = ValidationReport []

fetch :: Config -> EvidenceSnapshot BlobRef -> Acquisition BlobRef (Either FetchError [EvidenceChange BlobRef])
fetch (Config url) snapshot = do
  captured <- storeBlob (BlobDownload (HttpRequest "GET" (url <> "/bytes") [] "") (Just "sample.bin") Nothing)
  case captured of
    Right (BlobResponse 200 _ (Just ref@(BlobRef hash _ _ _))) -> do
      finished <- sendHttp (HttpRequest "GET" (url <> "/finish") [] "")
      case finished of
        Right (HttpResponse 200 _ _) -> do
          prior <- readEvidence snapshot (EvidenceId "file")
          pure $ case prior of
            Left problem -> Left problem
            Right old -> Right [(case old of Nothing -> NewEvidence; Just _ -> UpdatedEvidence)
              (EvidenceId "file") (Evidence (EvidenceFingerprint hash) [url] (Available ref))]
        _ -> pure (Left (FetchError "Failed after download"))
    _ -> pure (Left (FetchError "Download failed"))

attachment :: Text -> EvidenceSnapshot BlobRef -> CapturedRead BlobRef (Either FetchError BlobRef)
attachment key snapshot = do
  found <- readEvidence snapshot (EvidenceId key)
  pure $ case found of
    Right (Just (Evidence _ _ (Available ref))) -> Right ref
    _ -> Left (FetchError "Attachment unavailable")
