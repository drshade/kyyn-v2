{-# LANGUAGE OverloadedStrings #-}
module KyynPluginEntry where

import Kyyn.Plugin
import Kyyn.Plugin.Host
import Kyyn.Runtime.Json
import Kyyn.Runtime.Plugin (blobCodec)
import Kyyn.Runtime.PluginHost (executeAcquisitionResult)
import Data.Text (Text)

main :: IO ()
main = executeAcquisitionResult textCodec blobCodec blobCodec capture

capture :: Text -> EvidenceSnapshot BlobRef -> Acquisition BlobRef (Either FetchError BlobRef)
capture url _ = do
  result <- storeBlob (BlobDownload (HttpRequest "GET" url [] "") (Just "fixture.bin") Nothing)
  pure $ case result of
    Left problem -> Left problem
    Right (BlobResponse 200 _ (Just ref)) -> Right ref
    Right _ -> Left (FetchError "Download refused")
