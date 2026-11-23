module Kyyn.Domain.FlowBundleId (FlowBundleId, flowBundleId, flowBundleIdText, identifyBundle) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as Bytes
import qualified Crypto.Hash.SHA256 as SHA256
import Numeric (showHex)

newtype FlowBundleId = FlowBundleId String deriving (Eq, Ord, Show)
flowBundleId :: String -> Either String FlowBundleId
flowBundleId value
  | length value == 64 && all (`elem` (['0'..'9'] ++ ['a'..'f'])) value = Right (FlowBundleId value)
  | otherwise = Left "Invalid execution bundle identity"
flowBundleIdText :: FlowBundleId -> String
flowBundleIdText (FlowBundleId value) = value
identifyBundle :: ByteString -> FlowBundleId
identifyBundle = FlowBundleId . concatMap hex . Bytes.unpack . SHA256.hash
  where hex byte = let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits
