module Kyyn.Plumbing.Protocol.Tool (ToolCall(..), JournalCall(..), FlowControlCall(..), decodeToolFrame, decodeFlowValue, encodeFlowValue, encodeJournalLookup) where

import Control.Monad (unless)
import Kyyn.Types.FlowObservation
import Agentic.Aeson (toAeson, fromAeson)
import qualified Kyyn.Runtime.Json as Wire
import Kyyn.Runtime.ModelWire (valueCodec)
import Data.Aeson (Value, withObject, (.:))
import Data.Text (Text)
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.List (sort)
import Kyyn.Domain.Plugin
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Types.Contract (Description)
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
  | ToolFlowObserved FlowObservation
  | ToolJournal JournalCall
  | ToolLiveQuery PluginName ConnectorTypeName ConnectorName MethodName Description Description Value
  | ToolFlowControl FlowControlCall

data FlowControlCall = StartChildCall Text Text RecipeId Description Description Value
  | InspectChildCall Text Description | CancelChildCall Text Description Bool

data JournalCall = InitialiseJournal Text Text | LookupJournal Value | SaveJournal Value Value


decodeToolFrame :: Bytes.ByteString -> Either String (PluginFrame ToolCall)
decodeToolFrame = decodeFrameWith $ \capability operation arguments ->
  if capability == "judgement" && operation == "evaluate"
  then ToolJudgement <$> Judgement.decodeRequest arguments
  else if capability == "model" && operation == "turn"
  then ToolModel <$> Model.decodeRequest arguments
  else if capability == "flow" && operation == "observe"
  then ToolFlowObserved <$> withObject "flow observation" (\o -> do
    unless (sort (Keys.keys o) == ["operation","summary"]) (fail "Unexpected observation fields")
    summary <- o .: "summary" >>= either fail pure . Wire.decodeWith valueCodec
    identity <- o .: "operation" >>= either fail pure . Wire.decodeWith (Wire.optionalCodec valueCodec)
    pure (FlowObservation (FlowSummary summary) (OperationIdentity <$> identity))) arguments
  else if capability == "flow-control"
  then ToolFlowControl <$> decodeControl operation arguments
  else if capability == "flow-journal"
  then ToolJournal <$> decodeJournal operation arguments
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
    ("plugin","query") -> do
      exact ["connectorType","input","inputContract","instance","method","outputContract","plugin"]
      ToolLiveQuery plugin kind instanceName <$> (fields .: "method" >>= checked . methodName)
        <*> fields .: "inputContract" <*> fields .: "outputContract" <*> fields .: "input"
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

encodeFlowValue :: Value -> Value
encodeFlowValue = Wire.encodeWith valueCodec . fromAeson

encodeJournalLookup :: Maybe Value -> Value
-- Keep the tagged value verbatim: converting through plain JSON loses distinctions
-- such as an integral Double versus an Integer in a durable result.
encodeJournalLookup = Wire.encodeWith (Wire.optionalCodec (Wire.Codec id Right))

decodeJournal :: String -> Value -> Parser JournalCall
decodeJournal operation = withObject "flow journal request" $ \fields -> do
  let exact names = unless (sort (Keys.keys fields) == names) (fail "Unexpected journal fields")
  case operation of
    "initialise" -> exact ["namespace","revision"] >>
      InitialiseJournal <$> fields .: "namespace" <*> fields .: "revision"
    "lookup" -> exact ["key"] >> LookupJournal <$> (fields .: "key" >>= checkedValue)
    "save" -> exact ["key","value"] >> SaveJournal <$> (fields .: "key" >>= checkedValue)
      <*> (fields .: "value" >>= checkedValue)
    _ -> fail "Unknown journal operation"

checkedValue :: Value -> Parser Value
checkedValue value = case Wire.decodeWith valueCodec value of
  Left message -> fail message
  Right _ -> pure value

decodeControl :: String -> Value -> Parser FlowControlCall
decodeControl operation = withObject "interactive control" $ \fields -> case operation of
  "start" -> do
    unless (sort (Keys.keys fields) == ["child","input","inputContract","key","namespace","outputContract"]) (fail "Unexpected child start fields")
    StartChildCall <$> fields .: "namespace" <*> fields .: "key" <*> (RecipeId <$> fields .: "child") <*> fields .: "inputContract" <*> fields .: "outputContract" <*> fields .: "input"
  "inspect" -> do
    unless (sort (Keys.keys fields) == ["id","outputContract"]) (fail "Unexpected child inspection fields")
    InspectChildCall <$> fields .: "id" <*> fields .: "outputContract"
  "cancel" -> do
    unless (sort (Keys.keys fields) == ["descendants","id","outputContract"]) (fail "Unexpected child cancellation fields")
    CancelChildCall <$> fields .: "id" <*> fields .: "outputContract" <*> fields .: "descendants"
  _ -> fail "Unknown interactive control operation"
