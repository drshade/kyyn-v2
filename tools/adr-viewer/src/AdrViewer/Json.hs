-- | Stable, diff-friendly JSON files: fixed key order and two-space indentation,
-- so regenerated evidence and agent-edited lanes produce reviewable diffs.
{-# LANGUAGE OverloadedStrings #-}
module AdrViewer.Json (writeJson, readJson, encodeCompact) where

import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict', encode)
import Data.Aeson.Encode.Pretty (Config(..), Indent(..), defConfig, encodePretty', keyOrder)
import qualified Data.ByteString.Lazy as BL

writeJson :: ToJSON a => FilePath -> a -> IO ()
writeJson path = BL.writeFile path . (<> "\n") . encodePretty' config
  where
    config = defConfig { confIndent = Spaces 2, confCompare = keyOrder order }
    order = [ "adr", "id", "seq", "sha", "date", "pr", "title", "cursor", "summary", "detail"
            , "kind", "supersedes", "sections", "anchors", "realised", "how", "evidence"
            , "ended", "by", "confidence", "born", "deleted", "adrs", "name", "url"
            , "nodes", "editorial", "note", "notes" ]

readJson :: FromJSON a => FilePath -> IO (Either String a)
readJson path = either (Left . ((path <> ": ") <>)) Right <$> eitherDecodeFileStrict' path

encodeCompact :: ToJSON a => a -> BL.ByteString
encodeCompact = encode
