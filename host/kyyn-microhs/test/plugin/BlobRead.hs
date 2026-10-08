{-# LANGUAGE OverloadedStrings #-}
module KyynPluginEntry where

import Kyyn.Plugin
import Kyyn.Runtime.Json
import Kyyn.Runtime.Plugin (blobCodec, executeCapturedRead)
import qualified Data.ByteString as Bytes
import Data.Text (Text)

main :: IO ()
main = executeCapturedRead blobCodec blobCodec textCodec readCaptured

readCaptured :: BlobRef -> EvidenceSnapshot BlobRef -> CapturedRead BlobRef (Either FetchError Text)
readCaptured ref _ = do
  binary <- readBlob ref
  text <- readBlobText ref
  pure $ case (binary,text) of
    (Right bytes,Left _) | bytes == Bytes.pack [0..255] -> Right "binary, not UTF-8"
    _ -> Left (FetchError "Blob transport changed content or accepted invalid UTF-8")
