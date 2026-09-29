module Kyyn.Plumbing.Protocol.PluginMessages
  ( PluginFrame(..), PluginCall(..), decodeFrame, decodeCall, decodeFrameWith, encodeResponse, initialInput
  , parseResult, parseChanges, changesShape, evidenceValue, success, failure ) where

import Control.Monad (unless)
import Data.Aeson (Value(..), Object, object, (.=), (.:), eitherDecodeStrict, encode, withObject, withArray, parseJSON)
import Data.Aeson.Types (Parser, parseEither)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.Foldable (toList)
import Data.List (sort)
import Kyyn.Domain.Contract (CheckedContract, contractId)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Evidence
import Kyyn.Domain.Value (CheckedValue(..))

data PluginCall = ListFiles FilePath Bool | ReadText FilePath
  | ListEvidence String | ReadEvidence String EvidenceId deriving (Eq, Show)
data PluginFrame call = HostRequest Integer call | Completed Value deriving (Eq, Show)

decodeFrame :: Bytes.ByteString -> Either String (PluginFrame PluginCall)
decodeFrame = decodeFrameWith decodeCall

decodeCall :: String -> String -> Value -> Parser PluginCall
decodeCall capability method arguments = case (capability, method) of
  ("files","list") -> exact ["directory","recursive"] (\a -> ListFiles <$> a .: "directory" <*> a .: "recursive") arguments
  ("files","read") -> exact ["path"] (fmap ReadText . (.: "path")) arguments
  ("evidence","list") -> exact ["snapshot"] (fmap ListEvidence . (.: "snapshot")) arguments
  ("evidence","read") -> exact ["snapshot","id"] (\a -> ReadEvidence <$> a .: "snapshot" <*> (EvidenceId <$> a .: "id")) arguments
  _ -> fail "Unsupported plugin capability or method"

decodeFrameWith :: (String -> String -> Value -> Parser call) -> Bytes.ByteString -> Either String (PluginFrame call)
decodeFrameWith parseCall bytes = eitherDecodeStrict bytes >>= parseEither (withObject "plugin frame" $ \o -> do
  tag <- o .: "tag"
  case tag :: String of
    "Completed" -> exactFields ["tag","result"] o >> Completed <$> o .: "result"
    "HostRequest" -> do
      exactFields ["tag","id","capability","method","arguments"] o
      text <- o .: "id"
      identity <- case reads text of
        [(n, "")] | n > 0 && show (n :: Integer) == text -> pure n
        _ -> fail "Expected positive canonical request ID"
      capability <- o .: "capability"
      method <- o .: "method"
      arguments <- o .: "arguments"
      call <- parseCall capability method arguments
      pure (HostRequest identity call)
    _ -> fail "Unknown plugin frame tag")

exact :: [Key] -> (Object -> Parser a) -> Value -> Parser a
exact expected parse = withObject "plugin value" $ \o -> exactFields expected o >> parse o
exactFields :: [Key] -> Object -> Parser ()
exactFields expected o = unless (sort (Keys.keys o) == sort expected) (fail "Unexpected or missing plugin fields")

initialInput :: Value -> Bytes.ByteString
initialInput value = Lazy.toStrict (encode (object ["arguments" .= value,"snapshot" .= ("selected" :: String)]))

encodeResponse :: Integer -> Value -> Bytes.ByteString
encodeResponse identity value = Lazy.toStrict (encode (object
  ["tag" .= ("HostResponse" :: String),"id" .= show identity,"result" .= value]))

success :: Value -> Value
success value = object ["tag" .= ("Right" :: String),"value" .= value]
failure :: String -> Value
failure message = object ["tag" .= ("Left" :: String),"value" .= message]

parseResult :: Value -> Either String (Either String Value)
parseResult = parseEither (exact ["tag","value"] $ \o -> do
  tag <- o .: "tag"
  case tag :: String of
    "Left" -> Left <$> o .: "value"
    "Right" -> Right <$> o .: "value"
    _ -> fail "Expected typed Left or Right result")

evidenceValue :: Evidence CheckedValue -> Value
evidenceValue (Evidence (EvidenceFingerprint fingerprint) refs (CheckedValue _ payload)) =
  object ["fingerprint" .= fingerprint,"references" .= refs,"payload" .= payload]

changesShape :: Shape -> Shape
changesShape payload = List (Union [("New",Just entry),("Updated",Just entry),("Removed",Just text)])
  where
    text = Scalar TextScalar
    entry = Record [("id",text),("evidence",Record [("fingerprint",text),("references",List text),("payload",payload)])]

parseChanges :: CheckedContract -> Value -> Either String [EvidenceChange CheckedValue]
parseChanges contract = parseEither (withArray "evidence changes" (traverse change . toList))
  where
    change = exact ["tag","value"] $ \o -> do
      tag <- o .: "tag"
      value <- o .: "value"
      case tag :: String of
        "New" -> entry NewEvidence value
        "Updated" -> entry UpdatedEvidence value
        "Removed" -> RemovedEvidence . EvidenceId <$> parseJSON value
        _ -> fail "Unknown evidence change"
    entry constructor = exact ["id","evidence"] $ \o -> do
      key <- EvidenceId <$> o .: "id"
      payload <- o .: "evidence" >>= exact ["fingerprint","references","payload"] (\e ->
        Evidence <$> (EvidenceFingerprint <$> e .: "fingerprint") <*> e .: "references"
          <*> (CheckedValue (contractId contract) <$> e .: "payload"))
      pure (constructor key payload)
