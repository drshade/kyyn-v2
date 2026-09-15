{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Connectors (connectorListResult, schemaResult, fetchResult, historyResult, changesResult, clearResult) where

import Data.Aeson (Value, object, (.=))
import Data.Coerce (Coercible, coerce)
import qualified Data.Text as Text
import Kyyn.Domain.Evidence
import Kyyn.Domain.Plugin
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Surfaces.Result (Response, success)

connectorListResult :: PluginName -> [(ConnectorName,BindingName,ConnectorTypeName)] -> Response
connectorListResult plugin connectors = success
  (object ["plugin" .= pluginNameText plugin,"connectors" .=
    [object ["name" .= text name,"binding" .= text binding,"type" .= text kind] | (name,binding,kind) <- connectors]])
  (if null connectors then ["No configured connectors for " ++ pluginNameText plugin]
   else [text name ++ "  " ++ text kind ++ "  binding=" ++ text binding | (name,binding,kind) <- connectors])

schemaResult :: PluginName -> Text.Text -> Response
schemaResult plugin schema = success (object ["plugin" .= pluginNameText plugin,"schema" .= schema]) [Text.unpack (Text.stripEnd schema)]

fetchResult :: EvidenceSnapshotRef -> Response
fetchResult snapshot@(EvidenceSnapshotRef (ConnectorInstanceRef plugin name) _ identity) = success (context snapshot)
  ["Fetched " ++ pluginNameText plugin ++ "/" ++ name, "Fetch: " ++ fetchName identity]

historyResult :: EvidenceSnapshotRef -> [FetchSummary] -> Response
historyResult snapshot fetches = success (object ["selection" .= context snapshot,"fetches" .=
  [object ["id" .= fetchName identity,"previous" .= fmap fetchName previous,"fetchedAt" .= at,"changeCount" .= count]
    | FetchSummary identity previous at count <- fetches]])
  [fetchName identity ++ "  " ++ at ++ "  " ++ show count ++ " changes" | FetchSummary identity _ at count <- fetches]

changesResult :: EvidenceSnapshotRef -> [EvidenceChangeSummary] -> Response
changesResult snapshot changes = success (object ["selection" .= context snapshot,"changes" .= map value changes])
  (if null changes then ["No evidence changes in the selected interval."] else
    [fetchName identity ++ "  " ++ show kind ++ "  " ++ key | EvidenceChangeSummary identity _ kind (EvidenceId key) _ _ <- changes])
  where
    value (EvidenceChangeSummary identity previous kind (EvidenceId key) (EvidenceFingerprint fingerprint) (EvidenceRef producer connector source refs)) = object
      ["fetch" .= fetchName identity,"previous" .= fmap fetchName previous,"kind" .= show kind,"id" .= key,
       "fingerprint" .= fingerprint,
       "citation" .= object ["producer" .= producer,"connector" .= connector,"source" .= source,"references" .= refs]]

clearResult :: PluginName -> ConnectorName -> Bool -> Response
clearResult plugin name existed = success
  (object ["plugin" .= pluginNameText plugin,"connector" .= text name,"cleared" .= existed])
  [(if existed then "Cleared evidence for " else "No cached evidence for ") ++ pluginNameText plugin ++ "/" ++ text name]

context :: EvidenceSnapshotRef -> Value
context (EvidenceSnapshotRef (ConnectorInstanceRef plugin name) _ identity) = object
  ["plugin" .= pluginNameText plugin,"connector" .= name,"fetch" .= fetchName identity]
fetchName :: FetchId -> String
fetchName (FetchId name) = name
text :: Coercible a String => a -> String
text = coerce
