{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Connectors (connectorListResult, schemaResult, fetchResult, historyResult, changesResult, clearResult,
  evidenceListResult, evidenceItemResult, connectorResult, loginResult, methodListResult, methodResult, methodOutputResult) where

import Data.Aeson (Value, object, (.=))
import Data.Coerce (Coercible, coerce)
import qualified Data.Text as Text
import Kyyn.Domain.Evidence
import Kyyn.Domain.Plugin
import Kyyn.Types.Evidence (EvidenceRef(..))
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
evidenceListResult (EvidenceCapture snapshot items) = success
  (object ["selection" .= context snapshot, "items" .=
    [object ["id" .= key,"fingerprint" .= fingerprint] | (EvidenceId key,EvidenceFingerprint fingerprint) <- items]])
  (if null items then ["No current evidence."] else
    [Text.unpack key ++ "  " ++ Text.unpack fingerprint | (EvidenceId key,EvidenceFingerprint fingerprint) <- items])

evidenceItemResult :: EvidenceSnapshotRef -> EvidenceId -> Evidence CheckedValue -> Text.Text -> Response
evidenceItemResult snapshot (EvidenceId key) (Evidence (EvidenceFingerprint fingerprint) refs (CheckedValue _ payload)) rendered = success
  (object ["selection" .= context snapshot, "id" .= key, "fingerprint" .= fingerprint,
    "references" .= refs, "payload" .= payload])
  (["Evidence: " ++ Text.unpack key, "Fingerprint: " ++ Text.unpack fingerprint] ++
    ["Source: " ++ Text.unpack ref | ref <- refs] ++ [Text.unpack (Text.stripEnd rendered)])

historyResult :: EvidenceSnapshotRef -> [FetchSummary] -> Response
historyResult snapshot fetches = success (object ["selection" .= context snapshot,"fetches" .=
  [object ["id" .= fetchName identity,"previous" .= fmap fetchName previous,"fetchedAt" .= at,"changeCount" .= count,"options" .= options]
    | FetchSummary identity previous at count options <- fetches]])
  [fetchName identity ++ "  " ++ at ++ "  " ++ show count ++ " changes" ++ maybe "" ("  options=" ++) options
    | FetchSummary identity _ at count options <- fetches]

changesResult :: EvidenceSnapshotRef -> [EvidenceChangeSummary] -> Response
changesResult snapshot changes = success (object ["selection" .= context snapshot,"changes" .= map value changes])
  (if null changes then ["No evidence changes in the selected interval."] else
    [fetchName identity ++ "  " ++ show kind ++ "  " ++ Text.unpack key | EvidenceChangeSummary identity _ kind (EvidenceId key) _ _ <- changes])
  where
    value (EvidenceChangeSummary identity previous kind (EvidenceId key) (EvidenceFingerprint fingerprint) (EvidenceRef producer connector source refs)) = object
      ["fetch" .= fetchName identity,"previous" .= fmap fetchName previous,"kind" .= show kind,"id" .= key,
       "fingerprint" .= fingerprint,
       "citation" .= object ["producer" .= producer,"instance" .= connector,"source" .= source,"references" .= refs]]

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
