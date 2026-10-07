module Kyyn.Plumbing.Protocol.Tool
  ( ConnectorInterface(..), InstanceBinding(..), toolBindings, toolSources, toolSourcesWithCodecs, ToolCall(..), decodeToolFrame ) where

import Control.Monad (unless)
import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.Coerce (coerce)
import Data.List (nub, sort)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.DataType (DataType(..), haskellType, typeModules)
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Domain.Plugin
import Kyyn.Types.Evidence (EvidenceId(..))
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)
import Kyyn.Plumbing.Protocol.PluginMessages (PluginFrame, decodeFrameWith)
import qualified Kyyn.Plumbing.Protocol.Judgement as Judgement
import Agentic.Questions (JudgeRequest)
import qualified Agentic.Runtime as Agentic
import qualified Kyyn.Plumbing.Protocol.ModelTurn as Model

data ConnectorInterface = ConnectorInterface PluginName ConnectorTypeName DataType [(MethodName,DataType,DataType)]
data InstanceBinding = InstanceBinding BindingName PluginName ConnectorTypeName ConnectorName
data ToolCall = ToolCall PluginName ConnectorTypeName ConnectorName MethodName Value
  | ToolEvidenceList PluginName ConnectorTypeName ConnectorName
  | ToolEvidenceRead PluginName ConnectorTypeName ConnectorName EvidenceId
  | ToolJudgement JudgeRequest
  | ToolModel Agentic.Conversation

proxyModule :: PluginName -> ConnectorTypeName -> String
proxyModule plugin kind = "Kyyn.Plugins.P_" ++ map (\c -> if c == '-' then '_' else c) (pluginNameText plugin) ++ "." ++ coerce kind

source :: String -> String -> Either String (RelativePath,Bytes.ByteString)
source name body = do
  path <- relativePath (map (\c -> if c == '.' then '/' else c) name ++ ".hs")
  pure (path,Text.encodeUtf8 (Text.pack ("{-# LANGUAGE OverloadedStrings #-}\n" ++ body)))

toolBindings :: [ConnectorInterface] -> [InstanceBinding] -> Either String [(RelativePath,Bytes.ByteString)]
toolBindings interfaces bindings = do
  let indexed = zip [0 :: Int ..] interfaces
      requests = [(i,p,k,n,a,b) | (i,ConnectorInterface p k _ methods) <- indexed, (n,a,b) <- methods]
      payloads = [payload | ConnectorInterface _ _ payload _ <- interfaces]
      calls = unlines $ ["{-# LANGUAGE GADTs, EmptyDataDecls #-}",
        "module KyynToolCalls (Calls(..)" ++ concat [", Connector" ++ show i | (i,_) <- indexed] ++ ") where",
        "import Kyyn.Types.Plugin (ConnectorInstance, FetchError)",
        "import Kyyn.Types.Evidence (EvidenceId, Evidence)",
        "import Agentic.Questions (JudgeRequest, Answer)",
        "import qualified Agentic.Runtime as Agentic"] ++ imports (payloads ++ concat [[a,b] | (_,_,_,_,a,b) <- requests]) ++
        ["data Connector" ++ show i | (i,_) <- indexed] ++
        ["data Calls a where", "  JudgementCall :: JudgeRequest -> Calls (Either String [Answer])",
         "  ModelCall :: Agentic.Conversation -> Calls (Either String Agentic.Turn)"] ++ concat
        [["  ListEvidence" ++ show i ++ " :: ConnectorInstance Connector" ++ show i ++ " -> Calls (Either FetchError [EvidenceId])",
          "  ReadEvidence" ++ show i ++ " :: ConnectorInstance Connector" ++ show i ++ " -> EvidenceId -> Calls (Either FetchError (Maybe (Evidence " ++ haskellType payload ++ ")))" ]
          | (i,ConnectorInterface _ _ payload _) <- indexed] ++
        ["  " ++ requestName i n ++ " :: ConnectorInstance Connector" ++ show i ++ " -> " ++ haskellType a ++
          " -> Calls (Either FetchError " ++ haskellType b ++ ")" | (i,_,_,n,a,b) <- requests]
  core <- source "KyynToolCalls" calls
  agenticModule <- source "Kyyn.Agentic" (unlines
    ["module Kyyn.Agentic (Step, Flow, interpret, liftTool) where",
     "import qualified Agentic as A", "import qualified Agentic.Runtime as A",
     "import Agentic.Runtime (Runtime(..))",
     "import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)",
     "import Control.Monad.Trans.Class (lift)",
     "import Kyyn.Types.Plugin (FetchError(..))", "import Kyyn.Types.Program (request)", "import qualified Data.Text as Text",
     "import Kyyn.Connectors (Tool)", "import qualified KyynToolCalls as Calls",
     "-- | An agentic flow using the current tool's host capabilities.",
     "type Flow input output = A.Agentic Step input output",
     "-- | A tool action that can fail with a fetch error, used inside a flow.",
     "type Step = ExceptT FetchError Tool",
     "-- | Execute a flow; model selection comes from root/model.dhall.",
     "interpret :: Flow input output -> input -> Tool (Either FetchError output)",
     "interpret flow input = runExceptT (A.interpret runtime flow input)",
     "runtime :: A.Runtime Step",
     "runtime = (A.runtimeWith (throwE . FetchError . Text.pack . show))",
     "  { systemOne = A.SystemOne $ \\question ->",
     "      lift (request (Calls.JudgementCall question)) >>= either (throwE . FetchError . Text.pack) pure",
     "  , systemTwo = A.SystemTwo $ \\conversation ->",
     "      lift (request (Calls.ModelCall conversation)) >>= either (throwE . FetchError . Text.pack) pure }",
     "-- | Lift a captured-read tool action into a flow's effect monad.",
     "liftTool :: Tool a -> Step a", "liftTool = lift"])
  proxies <- traverse (\(i,ConnectorInterface plugin kind _ methods) -> source (proxyModule plugin kind) (unlines $
    ["module " ++ proxyModule plugin kind ++ " (Instance" ++ concat [", " ++ coerce n | (n,_,_) <- methods] ++ ") where",
     "import Kyyn.Types.Plugin (ConnectorInstance, FetchError)","import Kyyn.Types.Program (Program)",
     "import qualified Kyyn.Types.Program as Program",
     "import qualified KyynToolCalls as Calls"] ++ imports (concat [[a,b] | (_,a,b) <- methods]) ++
    ["type Instance = ConnectorInstance Calls.Connector" ++ show i] ++ concat
    [[coerce n ++ " :: Instance -> " ++ haskellType a ++ " -> Program Calls.Calls (Either FetchError " ++ haskellType b ++ ")",
      coerce n ++ " instanceValue arguments = Program.request (Calls." ++ requestName i n ++ " instanceValue arguments)"] | (n,a,b) <- methods])) indexed
  evidenceModules <- traverse (\(i,ConnectorInterface plugin kind payload _) -> source (proxyModule plugin kind ++ ".Evidence") (unlines $
    ["module " ++ proxyModule plugin kind ++ ".Evidence (listEvidenceIds, readEvidence) where",
     "import " ++ proxyModule plugin kind ++ " (Instance)",
     "import Kyyn.Types.Evidence (EvidenceId, Evidence)",
     "import Kyyn.Types.Plugin (FetchError)",
     "import Kyyn.Types.Program (Program, request)",
     "import qualified KyynToolCalls as Calls"] ++ imports [payload] ++
    ["-- | List current evidence IDs in this connector instance.",
     "listEvidenceIds :: Instance -> Program Calls.Calls (Either FetchError [EvidenceId])",
     "listEvidenceIds = request . Calls.ListEvidence" ++ show i,
     "-- | Read current evidence, including its fingerprint, source references and typed payload.",
     "readEvidence :: Instance -> EvidenceId -> Program Calls.Calls (Either FetchError (Maybe (Evidence " ++ haskellType payload ++ ")))",
     "readEvidence instanceValue key = request (Calls.ReadEvidence" ++ show i ++ " instanceValue key)"])) indexed
  connectorModule <- source "Kyyn.Connectors" (unlines $
    ["module Kyyn.Connectors (Tool" ++ concat [", " ++ coerce n | InstanceBinding n _ _ _ <- bindings] ++ ") where",
     "import Kyyn.Types.Program (Program)","import Kyyn.Types.Plugin (ConnectorInstance(..))",
     "import qualified KyynToolCalls as Calls"] ++
    ["import qualified " ++ proxyModule p k | ConnectorInterface p k _ _ <- interfaces] ++
    ["-- | Effectful KB helper. Import Tool from Kyyn.Connectors and FetchError from Kyyn.Plugin.",
     "-- A registered implementation has type: Input -> Tool (Either FetchError Result).",
     "-- Register name, description, implementation, inputType and resultType in kb.dhall's tools list.",
     "-- Input and Result are the authored Haskell types named by that registration.",
     "type Tool = Program Calls.Calls"] ++ concat
    [[coerce n ++ " :: " ++ proxyModule p k ++ ".Instance",
      coerce n ++ " = ConnectorInstance " ++ show (coerce instanceName :: String)] | InstanceBinding n p k instanceName <- bindings])
  pure (core:connectorModule:agenticModule:proxies ++ evidenceModules)

toolSources :: [ConnectorInterface] -> [InstanceBinding] -> DataType -> DataType -> String
  -> [(RelativePath,Bytes.ByteString)] -> Either String GuestSources
toolSources interfaces bindings input output implementation authored = do
  inputCodecSource <- generateCodecs "KyynToolInputCodec" input
  outputCodecSource <- generateCodecs "KyynToolResultCodec" output
  toolSourcesWithCodecs interfaces bindings input output implementation inputCodecSource outputCodecSource authored

toolSourcesWithCodecs :: [ConnectorInterface] -> [InstanceBinding] -> DataType -> DataType -> String
  -> String -> String -> [(RelativePath,Bytes.ByteString)] -> Either String GuestSources
toolSourcesWithCodecs interfaces bindings input output implementation inputSource outputSource authored = do
  implementationModule <- bindingModule implementation
  generated <- toolBindings interfaces bindings
  boundaryCodecs <- sequence [source "KyynToolInputCodec" inputSource, source "KyynToolResultCodec" outputSource]
  let indexed = zip [0 :: Int ..] interfaces
      methods = [(i,p,k,n,a,b) | (i,ConnectorInterface p k _ ms) <- indexed, (n,a,b) <- ms]
  codecs <- traverse (\(name,datatype) -> generateCodecs name datatype >>= source name)
    ([(payloadCodec i,payload) | (i,ConnectorInterface _ _ payload _) <- indexed] ++
      concat [[(inputCodec i n,a),(resultCodec i n,b)] | (i,_,_,n,a,b) <- methods])
  entry <- source "KyynToolEntry" (unlines $
    ["{-# LANGUAGE GADTs, EmptyCase #-}","module KyynToolEntry where",
     "import qualified " ++ implementationModule,"import qualified Kyyn.Connectors as Connectors",
     "import qualified KyynToolCalls as Calls","import Kyyn.Types.Plugin (ConnectorInstance(..), FetchError)",
     "import Kyyn.Runtime.Json","import Kyyn.Runtime.Plugin (execute, exchange, eitherCodec, identityCodec, evidenceCodec)",
     "import Kyyn.Runtime.Transport (Transport, withTransport, readJson)",
     "import Kyyn.Runtime.Judgement (exchangeJudgement)",
     "import Kyyn.Runtime.Model (exchangeModel)",
     "import qualified KyynToolInputCodec as Input","import qualified KyynToolResultCodec as Output"] ++
    ["import qualified " ++ payloadCodec i | (i,_) <- indexed] ++
    ["import qualified " ++ m | (i,_,_,n,_,_) <- methods, m <- [inputCodec i n,resultCodec i n]] ++ imports [input,output] ++
    ["selected :: " ++ haskellType input ++ " -> Connectors.Tool (Either FetchError " ++ haskellType output ++ ")",
     "selected = " ++ implementation,"main :: IO ()","main = withTransport $ \\transport -> do","  line <- readJson transport",
     "  arguments <- either fail pure (parseValue line >>= decodeWith Input.rootCodec)",
     "  execute transport (eitherCodec Output.rootCodec) (dispatch transport) (selected arguments)",
     "dispatch :: Transport -> Integer -> Calls.Calls a -> IO a",
     "dispatch transport requestId (Calls.JudgementCall request) = exchangeJudgement transport requestId request",
     "dispatch transport requestId (Calls.ModelCall request) = exchangeModel transport requestId request"] ++ concat
    [["dispatch transport requestId (Calls.ListEvidence" ++ show i ++ " (ConnectorInstance instanceName)) =",
      "  exchange transport requestId \"evidence\" \"list\" (record [" ++ instanceFields p k ++ "])",
      "    (eitherCodec (listCodec identityCodec))",
      "dispatch transport requestId (Calls.ReadEvidence" ++ show i ++ " (ConnectorInstance instanceName) key) =",
      "  exchange transport requestId \"evidence\" \"read\" (record [" ++ instanceFields p k ++ ", (\"id\", encodeWith identityCodec key)])",
      "    (eitherCodec (optionalCodec (evidenceCodec " ++ payloadCodec i ++ ".rootCodec)))"]
      | (i,ConnectorInterface p k _ _) <- indexed] ++
    concat
      [["dispatch transport requestId (Calls." ++ requestName i n ++ " (ConnectorInstance instanceName) arguments) =",
        "  exchange transport requestId \"plugin\" \"read\" (record [",
        "    (\"plugin\", encodeWith stringCodec " ++ show (pluginNameText p) ++ "),",
        "    (\"connectorType\", encodeWith stringCodec " ++ show (coerce k :: String) ++ "),",
        "    (\"instance\", encodeWith textCodec instanceName),",
        "    (\"method\", encodeWith stringCodec " ++ show (coerce n :: String) ++ "),",
        "    (\"input\", encodeWith " ++ inputCodec i n ++ ".rootCodec arguments)])",
        "    (eitherCodec " ++ resultCodec i n ++ ".rootCodec)"] | (i,p,k,n,_,_) <- methods])
  guestSources (fst entry) (authored ++ generated ++ boundaryCodecs ++ codecs ++ [entry])

requestName :: Int -> MethodName -> String
requestName i n = "Call" ++ show i ++ "_" ++ coerce n
inputCodec, resultCodec :: Int -> MethodName -> String
inputCodec i n = "KyynToolInput" ++ show i ++ "_" ++ coerce n
resultCodec i n = "KyynToolResult" ++ show i ++ "_" ++ coerce n

payloadCodec :: Int -> String
payloadCodec i = "KyynToolPayload" ++ show i

instanceFields :: PluginName -> ConnectorTypeName -> String
instanceFields plugin kind = "(\"plugin\", encodeWith stringCodec " ++ show (pluginNameText plugin) ++
  "), (\"connectorType\", encodeWith stringCodec " ++ show (coerce kind :: String) ++
  "), (\"instance\", encodeWith textCodec instanceName)"

imports :: [DataType] -> [String]
imports types = ["import qualified " ++ name | name <- nub
  (concatMap typeModules types)]

decodeToolFrame :: Bytes.ByteString -> Either String (PluginFrame ToolCall)
decodeToolFrame = decodeFrameWith $ \capability operation arguments ->
  if capability == "judgement" && operation == "evaluate"
  then ToolJudgement <$> Judgement.decodeRequest arguments
  else if capability == "model" && operation == "turn"
  then ToolModel <$> Model.decodeRequest arguments
  else decodePlugin capability operation arguments

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
