{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Connectors (connectorListResult, schemaResult, fetchResult, clearResult,
  evidenceListResult, evidenceItemResult, evidenceBatchResult, connectorResult, loginResult, methodListResult, methodResult, methodOutputResult) where

import Data.Aeson (Value(..), encode, object, (.=))
import Data.Coerce (Coercible, coerce)
import qualified Data.Text as Text
import Kyyn.Domain.Evidence
import Kyyn.Domain.Blob (ResolvedBlob(..), blobValue)
import Kyyn.Domain.Plugin
import Kyyn.Domain.Value (CheckedValue(..))
import Data.Aeson.Types (Pair)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as Bytes
import qualified Data.Text.Encoding as Encoding
import Data.Foldable (toList)
import Kyyn.Surfaces.Result (Response, success)

connectorListResult :: PluginName -> [(ConnectorName,BindingName,ConnectorTypeName)] -> Response
connectorListResult plugin connectors = success
  (object ["plugin" .= pluginNameText plugin,"connectors" .=
    [object ["name" .= text name,"binding" .= text binding,"type" .= text kind] | (name,binding,kind) <- connectors]])
  (if null connectors then ["No configured connectors for " ++ pluginNameText plugin]
   else [text name ++ "  " ++ text kind ++ "  binding=" ++ text binding | (name,binding,kind) <- connectors])

schemaResult :: PluginName -> Text.Text -> Response
schemaResult plugin schema = success (object ["plugin" .= pluginNameText plugin,"schema" .= schema]) [Text.unpack (Text.stripEnd schema)]

connectorResult :: PluginName -> ConnectorName -> Maybe Text.Text -> Maybe Text.Text -> Response
connectorResult plugin name options report = success
  (object ["plugin" .= pluginNameText plugin,"instance" .= text name,"fetchOptionsType" .= options,"reportType" .= report])
  [pluginNameText plugin ++ "/" ++ text name, maybe "Fetch options: none" (("Fetch options:\n" ++) . Text.unpack) options, maybe "Report: none" (("Report:\n" ++) . Text.unpack) report]

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

methodOutputResult :: Value -> Text.Text -> [ResolvedBlob] -> Response
methodOutputResult value rendered [] = success value [Text.unpack (Text.stripEnd rendered)]
methodOutputResult value rendered blobs = success
  (object ["value" .= value,"blobs" .= [object ["reference" .= blobValue ref,"path" .= path] | ResolvedBlob ref path <- blobs]])
  (Text.unpack (Text.stripEnd rendered) : ["Blob: " ++ path | ResolvedBlob _ path <- blobs])

fetchResult :: EvidenceSnapshotRef -> Response
fetchResult snapshot@(EvidenceSnapshotRef (ConnectorInstanceRef plugin name) _ identity) = success (context snapshot)
  ["Fetched " ++ pluginNameText plugin ++ "/" ++ name, "Fetch: " ++ fetchName identity]

evidenceListResult :: EvidenceCapture -> Response
evidenceListResult (EvidenceCapture snapshot latest items report) = success
  (object ["selection" .= context snapshot, "latest" .= summaryValue latest report, "items" .=
    [object ["id" .= key,"fingerprint" .= fingerprint,"availability" .= availability payload] | (EvidenceId key,EvidenceFingerprint fingerprint,payload) <- items]])
  (summaryLines latest report ++ if null items then ["No current evidence."] else
    [Text.unpack key ++ "  " ++ Text.unpack fingerprint ++ "  " ++ availability payload | (EvidenceId key,EvidenceFingerprint fingerprint,payload) <- items])
  where
    availability (Available ()) = "Available" :: String
    availability Truncated = "Truncated"

evidenceItemResult :: EvidenceSnapshotRef -> FetchSummary -> EvidenceId -> Evidence CheckedValue -> [ResolvedBlob] -> Maybe FetchReport -> Text.Text -> Response
evidenceItemResult snapshot latest key item blobs report rendered = success
  (object (["selection" .= context snapshot, "latest" .= summaryValue latest report] ++ itemFields key item blobs))
  (summaryLines latest report ++ itemLines key item blobs ++ [Text.unpack (Text.stripEnd rendered)])

itemFields :: EvidenceId -> Evidence CheckedValue -> [ResolvedBlob] -> [Pair]
itemFields (EvidenceId key) (Evidence (EvidenceFingerprint fingerprint) refs payload) blobs =
  ["id" .= key, "fingerprint" .= fingerprint, "externalReferences" .= refs, "payload" .= encodedPayload,
    "blobs" .= [object ["reference" .= blobValue ref,"path" .= path] | ResolvedBlob ref path <- blobs]]
  where
    encodedPayload = case payload of
      Available (CheckedValue _ value) -> object ["tag" .= ("Available" :: String),"value" .= value]
      Truncated -> object ["tag" .= ("Truncated" :: String)]

itemLines :: EvidenceId -> Evidence CheckedValue -> [ResolvedBlob] -> [String]
itemLines (EvidenceId key) (Evidence (EvidenceFingerprint fingerprint) refs payload) blobs =
  [Text.unpack key ++ "  " ++ Text.unpack fingerprint ++ "  " ++ availability] ++
  ["  Source: " ++ Text.unpack ref | ref <- refs] ++ ["  Blob: " ++ path | ResolvedBlob _ path <- blobs]
  where
    availability = case payload of Available _ -> "Available"; Truncated -> "Truncated"

summaryValue :: FetchSummary -> Maybe FetchReport -> Value
summaryValue (FetchSummary identity at added updated removed options) report = object
  ["id" .= fetchName identity,"fetchedAt" .= at,"added" .= added,"updated" .= updated,"removed" .= removed,"options" .= options,"report" .= reportValue report]

summaryLines :: FetchSummary -> Maybe FetchReport -> [String]
summaryLines (FetchSummary identity at added updated removed options) report =
  ["Latest fetch: " ++ fetchName identity ++ "  " ++ at ++ "  " ++ show added ++ " added, " ++ show updated ++ " updated, " ++ show removed ++ " removed"
    ++ maybe "" ("  options=" ++) options] ++ reportLines report

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

evidenceBatchResult :: EvidenceBatch -> Response
evidenceBatchResult (EvidenceBatch snapshot latest entries report) = success
  (object ["selection" .= context snapshot, "latest" .= summaryValue latest report,
    "items" .= [object (itemFields key item blobs) | (key,item,blobs) <- entries]])
  (summaryLines latest report ++ if null entries then ["No current evidence."] else
    concat [itemLines key item blobs | (key,item,blobs) <- entries])

reportValue :: Maybe FetchReport -> Value
reportValue Nothing = Null
reportValue (Just (FetchReport _ (CheckedValue _ value))) = value

reportLines :: Maybe FetchReport -> [String]
reportLines Nothing = ["No connector report was supplied."]
reportLines report = "Report from last successful fetch:" : preview 2 (reportValue report)
  where
    preview depth (Object fields) = concat
      [indent depth (Key.toString key ++ ":") : preview (depth+2) value | (key,value) <- KeyMap.toList fields]
    preview depth (Array values) =
      let entries = toList values; count = length entries
      in indent depth (show count ++ " entries") : concatMap (preview (depth+2)) (take 10 entries) ++
        [indent depth (show (count-10) ++ " omitted; use --json for the complete report") | count > 10]
    preview depth value = [indent depth (Text.unpack (Encoding.decodeUtf8 (Bytes.toStrict (encode value))))]
    indent depth value = replicate depth ' ' ++ value
