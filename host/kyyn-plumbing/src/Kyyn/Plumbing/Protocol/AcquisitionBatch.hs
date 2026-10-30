module Kyyn.Plumbing.Protocol.AcquisitionBatch
  ( AcquisitionFrame(..), decodeAcquisitionFrame, encodeBatchResponse, acquisitionInput ) where

import Control.Monad (unless)
import Data.Aeson (Value(..), Object, object, (.=), (.:), eitherDecodeStrict, encode)
import Data.Aeson.Types (Parser, parseEither, withObject)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.List (sort)
import Kyyn.Plumbing.Protocol.Frame (Frame(..))
import Kyyn.Plumbing.Protocol.PluginMessages (PluginFrame(..))

data AcquisitionFrame call = Single (PluginFrame call) | Batch [(Integer,call)]

acquisitionInput :: Int -> Value -> Bytes.ByteString
acquisitionInput width arguments = Lazy.toStrict (encode (object
  ["arguments" .= arguments,"snapshot" .= ("selected" :: String),"concurrency" .= show width]))

decodeAcquisitionFrame :: Int -> (Frame -> Either String (PluginFrame call)) -> Frame
  -> Either String (AcquisitionFrame call)
decodeAcquisitionFrame width decode frame@(Frame bytes body) = do
  value <- eitherDecodeStrict bytes
  grouped <- parseEither (withObject "acquisition frame" (\o -> (== ("HostBatch" :: String)) <$> o .: "tag")) value
  if not grouped then Single <$> decode frame else do
    parts <- parseEither (withObject "acquisition batch" $ \o -> do
      exact ["tag","requests"] o
      requests <- o .: "requests"
      unless (not (null requests) && length requests <= width) (fail "Invalid acquisition batch width")
      traverse part requests) value
    Batch <$> split parts body
  where
    part = withObject "batch request" $ \o -> do
      exact ["id","capability","method","arguments","bodyLength"] o
      identity <- o .: "id"
      capability <- o .: "capability"
      method <- o .: "method"
      arguments <- o .: "arguments"
      size <- o .: "bodyLength" >>= canonicalLength
      unless ((capability,method) `elem` allowed) (fail "Capability is forbidden in concurrent acquisition")
      if capability == "evidence" then withObject "snapshot request" (\args -> do
        token <- args .: "snapshot"
        unless (token == ("selected" :: String)) (fail "Unknown evidence snapshot handle")) arguments else pure ()
      pure (object ["tag" .= ("HostRequest" :: String),"id" .= (identity :: String),
        "capability" .= capability,"method" .= method,"arguments" .= (arguments :: Value)],size)
    split [] raw | Bytes.null raw = Right []
                 | otherwise = Left "Trailing acquisition batch body"
    split ((metadata,size):rest) raw
      | size > toInteger (Bytes.length raw) = Left "Truncated acquisition batch body"
      | otherwise = do
          let (partBody,remaining) = Bytes.splitAt (fromInteger size) raw
          request <- decode (Frame (Lazy.toStrict (encode metadata)) partBody)
          case request of
            HostRequest identity call -> ((identity,call):) <$> split rest remaining
            Completed _ -> Left "Terminal result inside acquisition batch"
    allowed :: [(String,String)]
    allowed = [("http","send"),("blobs","store"),("waiting","seconds"),("secrets","get"),
      ("files","list"),("files","read"),("evidence","list"),("evidence","read"),("digest","text")]

exact :: [String] -> Object -> Parser ()
exact names o = unless (sort (map Key.toString (Keys.keys o)) == sort names)
  (fail "Unexpected or missing batch fields")

canonicalLength :: String -> Parser Integer
canonicalLength text = case reads text of
  [(value,"")] | value >= 0 && show value == text -> pure value
  _ -> fail "Expected canonical nonnegative body length"

encodeBatchResponse :: [(Integer,(Value,Bytes.ByteString))] -> Frame
encodeBatchResponse replies = Frame (Lazy.toStrict (encode (object
  ["tag" .= ("HostBatchResponse" :: String),"responses" .=
    [object ["id" .= show identity,"result" .= value,"bodyLength" .= show (Bytes.length raw)]
    | (identity,(value,raw)) <- replies]]))) (Bytes.concat [raw | (_,(_,raw)) <- replies])
