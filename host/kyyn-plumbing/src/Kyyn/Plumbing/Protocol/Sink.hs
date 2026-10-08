module Kyyn.Plumbing.Protocol.Sink (decodeSinkCall, parseSinkResult, sinkRejection) where

import Control.Monad (unless)
import Data.Aeson (Value, Object, object, (.=), (.:), withObject)
import Data.Aeson.Types (Parser, parseEither)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.List (sort)
import Data.Text (Text)

decodeSinkCall :: String -> String -> Value -> Parser (FilePath,Text)
decodeSinkCall "files" "write" = exact ["path","content"] $ \fields -> (,) <$> fields .: "path" <*> fields .: "content"
decodeSinkCall _ _ = const (fail "Unsupported sink capability")

sinkRejection :: String -> Value
sinkRejection message = object ["tag" .= ("Left" :: String),"value" .= object
  ["kind" .= ("Rejected" :: String),"message" .= message]]

parseSinkResult :: Value -> Either String (Either (String,String) Value)
parseSinkResult = parseEither (exact ["tag","value"] $ \fields -> do
  tag <- fields .: "tag"
  case tag :: String of
    "Right" -> Right <$> fields .: "value"
    "Left" -> fields .: "value" >>= exact ["kind","message"] (\details -> do
      kind <- details .: "kind"
      unless (kind `elem` ["Rejected","Uncertain" :: String]) (fail "Unknown sink error kind")
      Left . (kind,) <$> details .: "message")
    _ -> fail "Unknown sink result")

exact :: [Key] -> (Object -> Parser a) -> Value -> Parser a
exact expected parse = withObject "sink value" $ \fields -> do
  unless (sort (Keys.keys fields) == sort expected) (fail "Unexpected or missing sink fields")
  parse fields
