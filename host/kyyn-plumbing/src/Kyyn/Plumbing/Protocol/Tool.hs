module Kyyn.Plumbing.Protocol.Tool (ToolCall(..), decodeToolFrame, decodeFlowValue) where

import Control.Monad (unless)
import Agentic.Aeson (toAeson)
import qualified Kyyn.Runtime.Json as Wire
import Kyyn.Runtime.ModelWire (valueCodec)
import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.List (sort)
import Kyyn.Domain.Plugin
import Kyyn.Types.Evidence (EvidenceId(..))
import Kyyn.Plumbing.Protocol.PluginMessages (PluginFrame, decodeFrameWith)
import qualified Kyyn.Plumbing.Protocol.Judgement as Judgement
import Agentic.Questions (JudgeRequest)
import qualified Agentic.Runtime as Agentic
import qualified Kyyn.Plumbing.Protocol.ModelTurn as Model

data ToolCall = ToolCall PluginName ConnectorTypeName ConnectorName MethodName Value
  | ToolEvidenceList PluginName ConnectorTypeName ConnectorName
  | ToolEvidenceRead PluginName ConnectorTypeName ConnectorName EvidenceId
  | ToolJudgement JudgeRequest
  | ToolModel Agentic.Conversation
  | ToolFlowObserved Value


decodeToolFrame :: Bytes.ByteString -> Either String (PluginFrame ToolCall)
decodeToolFrame = decodeFrameWith $ \capability operation arguments ->
  if capability == "judgement" && operation == "evaluate"
  then ToolJudgement <$> Judgement.decodeRequest arguments
  else if capability == "model" && operation == "turn"
  then ToolModel <$> Model.decodeRequest arguments
  else if capability == "flow" && operation == "observe"
  then ToolFlowObserved <$> decodeFlowValue arguments
  else decodePlugin capability operation arguments

decodeFlowValue :: Value -> Parser Value
decodeFlowValue = either fail (pure . toAeson) . Wire.decodeWith valueCodec

decodePlugin :: String -> String -> Value -> Parser ToolCall
decodePlugin capability operation = withObject "tool call" $ \fields -> do
  let checked = either fail pure
      exact names = unless (sort (Keys.keys fields) == names) (fail "Unexpected or missing tool call fields")
  plugin <- fields .: "plugin" >>= checked . pluginName
  kind <- fields .: "connectorType" >>= checked . connectorTypeName
  instanceName <- fields .: "instance" >>= checked . connectorName
  case (capability,operation) of
    ("plugin","read") -> do
      exact ["connectorType","input","instance","method","plugin"]
      ToolCall plugin kind instanceName <$> (fields .: "method" >>= checked . methodName) <*> fields .: "input"
    ("evidence","list") -> do
      exact ["connectorType","instance","plugin"]
      pure (ToolEvidenceList plugin kind instanceName)
    ("evidence","read") -> do
      exact ["connectorType","id","instance","plugin"]
      ToolEvidenceRead plugin kind instanceName . EvidenceId <$> fields .: "id"
    _ -> fail "Unsupported tool capability or method"
