{-# LANGUAGE OverloadedStrings, OverloadedRecordDot, DuplicateRecordFields #-}
module Kyyn.Plumbing.Protocol.RecipeRun
  ( headerValue, parseHeader, eventValue, parseEvent, summaryValue, listValue, pageValue ) where

import Data.Aeson (Value(..), Object, object, (.=), (.:), withObject, withText)
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.KeyMap as Keys
import Data.Aeson.Key (Key)
import Data.List (sort)
import qualified Data.ByteString.Char8 as Bytes
import qualified Data.Text as Text
import Numeric.Natural (Natural)
import Kyyn.Domain.RecipeRun
import Kyyn.Domain.CompiledProgram (BuildIdentity(..))
import Kyyn.Domain.Git (gitRevision, revisionName)
import Kyyn.Domain.Recipe (RecipeId(..), recipeId)
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Domain.Evolution (evolutionId, evolutionIdName)
import Kyyn.Domain.Diagnostic
import Kyyn.Plumbing.Protocol.Validation (parseReport)

headerValue :: RecipeRunHeader -> Value
headerValue h = let RecipeId recipe = h.recipe; FlowEntryRef flow = h.flow in object
  ["recipe" .= recipe,"flow" .= flow,"before" .= revisionName h.before,
   "startedAt" .= h.startedAt,"graph" .= h.graph,"build" .= object
    ["sourcesDigest" .= Bytes.unpack h.build.sourcesDigest,"targetSystem" .= h.build.targetSystem,
     "derivationPath" .= h.build.derivationPath,"outputPath" .= h.build.outputPath]]
parseHeader :: RecipeRunId -> Value -> Parser RecipeRunHeader
parseHeader identity = exact "run header" ["recipe","flow","before","startedAt","graph","build"] $ \o ->
  RecipeRunHeader identity <$> (o .: "recipe" >>= checked . recipeId)
    <*> (FlowEntryRef <$> o .: "flow") <*> (o .: "before" >>= checked . gitRevision)
    <*> (o .: "build" >>= exact "run build" ["sourcesDigest","targetSystem","derivationPath","outputPath"] (\b ->
      BuildIdentity <$> (Bytes.pack <$> b .: "sourcesDigest") <*> b .: "targetSystem" <*> b .: "derivationPath" <*> b .: "outputPath"))
    <*> o .: "startedAt" <*> o .: "graph"

eventValue :: RunEvent -> Value
eventValue (RunEvent elapsed body) = object ["elapsedNanos" .= show elapsed,"body" .= case body of
  FlowObserved summary -> object ["kind" .= String "flow","summary" .= summary]
  RunCompleted draft -> object ["kind" .= String "completed","draft" .= evolutionIdName draft]
  RunFailed diagnostics -> object ["kind" .= String "failed","diagnostics" .= map diagnostic diagnostics]
  RunCancelled -> object ["kind" .= String "cancelled"]]
parseEvent :: Value -> Parser RunEvent
parseEvent = exact "run event" ["elapsedNanos","body"] $ \o ->
  RunEvent <$> (o .: "elapsedNanos" >>= natural) <*> (o .: "body" >>= withObject "run event body" (\body -> do
    kind <- body .: "kind"
    case kind :: String of
      "flow" -> exactFields body ["kind","summary"] >> FlowObserved <$> body .: "summary"
      "completed" -> exactFields body ["kind","draft"] >> RunCompleted <$> (body .: "draft" >>= checked . evolutionId)
      "failed" -> do
        exactFields body ["kind","diagnostics"]
        ValidationReport ds <- body .: "diagnostics" >>= parseReport
        pure (RunFailed ds)
      "cancelled" -> exactFields body ["kind"] >> pure RunCancelled
      _ -> fail "Unknown run event kind"))
summaryValue :: RecipeRunSummary -> Value
summaryValue s = object ["runId" .= runIdText s.header.runId,"header" .= headerValue s.header,"status" .= statusName s.status,
  "draft" .= case s.status of Completed draft -> some (String (Text.pack (evolutionIdName draft))); _ -> none,
  "eventCount" .= show s.eventCount]
listValue :: RecipeRunSummary -> Value
listValue s = let RecipeId recipe = s.header.recipe in object
  ["runId" .= runIdText s.header.runId,"recipe" .= recipe,"startedAt" .= s.header.startedAt,
   "status" .= statusName s.status,"eventCount" .= show s.eventCount,
   "draft" .= case s.status of Completed draft -> some (String (Text.pack (evolutionIdName draft))); _ -> none]
pageValue :: RecipeRunPage -> Value
pageValue page = object ["summary" .= listValue page.summary,
  "events" .= [object ["sequence" .= show n,"event" .= eventValue e] | SequencedRunEvent n e <- page.events],
  "next" .= maybe none (some . String . Text.pack . show) page.next,"more" .= page.more,"incompleteTail" .= page.incompleteTail]
statusName :: RunStatus -> String
statusName Active = "active"
statusName Interrupted = "interrupted"
statusName (Completed _) = "completed"
statusName Failed = "failed"
statusName Cancelled = "cancelled"

none :: Value
none = object ["tag" .= String "None"]
some :: Value -> Value
some value = object ["tag" .= String "Some","value" .= value]
diagnostic :: Diagnostic -> Value
diagnostic (Diagnostic severity code message location) = object
  ["severity" .= object ["tag" .= show severity],"code" .= code,"message" .= message,
   "location" .= maybe none (some . place) location]
  where
    place (FactLocation collection identity field) = object ["tag" .= String "Fact","value" .= object
      ["collection" .= collection,"factId" .= identity,"field" .= maybe none (some . String) field]]
    place (SourceLocation file line column) = object ["tag" .= String "Source","value" .= object
      ["file" .= file,"line" .= show line,"column" .= show column]]
    place (ExampleLocation name) = object ["tag" .= String "Example","value" .= name]

natural :: Value -> Parser Natural
natural = withText "canonical natural" $ \text -> case reads (Text.unpack text) of
  [(n,"")] | n >= (0 :: Integer), show n == Text.unpack text -> pure (fromInteger n)
  _ -> fail "Expected a canonical natural"
checked :: Either String a -> Parser a
checked = either fail pure
exact :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
exact label names action = withObject label (\o -> exactFields o names >> action o)
exactFields :: Object -> [Key] -> Parser ()
exactFields o names | sort (Keys.keys o) == sort names = pure ()
                    | otherwise = fail "Unexpected or missing fields"
