{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Connectors (connectorListResult, schemaResult, fetchResult, clearResult,
  evidenceListResult, evidenceItemResult, connectorResult, loginResult, methodListResult, methodResult, methodOutputResult) where

import Data.Aeson (Value, object, (.=))
import Data.Coerce (Coercible, coerce)
import qualified Data.Text as Text
import Kyyn.Domain.Evidence
import Kyyn.Domain.Plugin
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Surfaces.Result (Response, success)

connectorListResult :: PluginName -> [(ConnectorName,BindingName,ConnectorTypeName)] -> Response
connectorListResult plugin connectors = success
  (object ["plugin" .= pluginNameText plugin,"connectors" .=
    [object ["name" .= text name,"binding" .= text binding,"type" .= text kind] | (name,binding,kind) <- connectors]])
  (if null connectors then ["No configured connectors for " ++ pluginNameText plugin]
   else [text name ++ "  " ++ text kind ++ "  binding=" ++ text binding | (name,binding,kind) <- connectors])

schemaResult :: PluginName -> Text.Text -> Response
schemaResult plugin schema = success (object ["plugin" .= pluginNameText plugin,"schema" .= schema]) [Text.unpack (Text.stripEnd schema)]

connectorResult :: PluginName -> ConnectorName -> Maybe Text.Text -> Response
connectorResult plugin name options = success
  (object ["plugin" .= pluginNameText plugin,"instance" .= text name,"fetchOptionsType" .= options])
  [pluginNameText plugin ++ "/" ++ text name, maybe "Fetch options: none" (("Fetch options:\n" ++) . Text.unpack) options]

loginResult :: PluginName -> ConnectorName -> Response
loginResult plugin name = success (object ["plugin" .= pluginNameText plugin,"instance" .= text name])
  ["Logged in: " ++ pluginNameText plugin ++ "/" ++ text name]

methodListResult :: [(MethodName,String)] -> Response
methodListResult methods = success
  (object ["methods" .= [object ["name" .= text name,"description" .= description] | (name,description) <- methods]])
  (if null methods then ["No captured-evidence methods."] else [text name ++ "  " ++ description | (name,description) <- methods])

methodResult :: MethodName -> String -> Text.Text -> Text.Text -> Response
methodResult name description input output = success
  (object ["name" .= text name,"description" .= description,"inputType" .= input,"resultType" .= output])
  [text name ++ " — " ++ description,"Input: " ++ Text.unpack input,"Result: " ++ Text.unpack output]

methodOutputResult :: Value -> Text.Text -> Response
methodOutputResult value rendered = success value [Text.unpack (Text.stripEnd rendered)]

fetchResult :: EvidenceSnapshotRef -> Response
fetchResult snapshot@(EvidenceSnapshotRef (ConnectorInstanceRef plugin name) _ identity) = success (context snapshot)
  ["Fetched " ++ pluginNameText plugin ++ "/" ++ name, "Fetch: " ++ fetchName identity]

evidenceListResult :: EvidenceCapture -> Response
evidenceListResult (EvidenceCapture snapshot latest items) = success
  (object ["selection" .= context snapshot, "latest" .= summaryValue latest, "items" .=
    [object ["id" .= key,"fingerprint" .= fingerprint,"availability" .= availability payload] | (EvidenceId key,EvidenceFingerprint fingerprint,payload) <- items]])
  (summaryLines latest ++ if null items then ["No current evidence."] else
    [Text.unpack key ++ "  " ++ Text.unpack fingerprint ++ "  " ++ availability payload | (EvidenceId key,EvidenceFingerprint fingerprint,payload) <- items])
  where
    availability (Available ()) = "Available" :: String
    availability Truncated = "Truncated"

evidenceItemResult :: EvidenceSnapshotRef -> FetchSummary -> EvidenceId -> Evidence CheckedValue -> Text.Text -> Response
evidenceItemResult snapshot latest (EvidenceId key) (Evidence (EvidenceFingerprint fingerprint) refs payload) rendered = success
  (object ["selection" .= context snapshot, "latest" .= summaryValue latest, "id" .= key, "fingerprint" .= fingerprint,
    "externalReferences" .= refs, "payload" .= encodedPayload])
  (summaryLines latest ++ ["Evidence: " ++ Text.unpack key, "Fingerprint: " ++ Text.unpack fingerprint] ++
    ["Source: " ++ Text.unpack ref | ref <- refs] ++ [Text.unpack (Text.stripEnd rendered)])
  where
    encodedPayload = case payload of
      Available (CheckedValue _ value) -> object ["tag" .= ("Available" :: String),"value" .= value]
      Truncated -> object ["tag" .= ("Truncated" :: String)]

summaryValue :: FetchSummary -> Value
summaryValue (FetchSummary identity at added updated removed options) = object
  ["id" .= fetchName identity,"fetchedAt" .= at,"added" .= added,"updated" .= updated,"removed" .= removed,"options" .= options]

summaryLines :: FetchSummary -> [String]
summaryLines (FetchSummary identity at added updated removed options) =
  ["Latest fetch: " ++ fetchName identity ++ "  " ++ at ++ "  " ++ show added ++ " added, " ++ show updated ++ " updated, " ++ show removed ++ " removed"
    ++ maybe "" ("  options=" ++) options]

clearResult :: PluginName -> ConnectorName -> Bool -> Response
clearResult plugin name existed = success
  (object ["plugin" .= pluginNameText plugin,"instance" .= text name,"cleared" .= existed])
  [(if existed then "Cleared evidence for " else "No cached evidence for ") ++ pluginNameText plugin ++ "/" ++ text name]

context :: EvidenceSnapshotRef -> Value
context (EvidenceSnapshotRef (ConnectorInstanceRef plugin name) _ identity) = object
  ["plugin" .= pluginNameText plugin,"instance" .= name,"fetch" .= fetchName identity]
fetchName :: FetchId -> String
fetchName (FetchId name) = name
text :: Coercible a String => a -> String
text = coerce
