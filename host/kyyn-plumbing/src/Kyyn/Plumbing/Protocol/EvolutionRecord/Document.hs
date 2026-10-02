module Kyyn.Plumbing.Protocol.EvolutionRecord.Document
  ( recordDocument, recordShape, openRecipeRecordShape, previousRecordShape, legacyRecordShape, headerShape, decodeHeader, decodeRecord ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=), withObject, (.:), (.:?), (.!=))
import Data.Aeson.Types (Parser, parseEither, parseJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as Keys
import Data.List (nub, sort, sortOn)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution (EvolutionId, evolutionId, evolutionIdName)
import Kyyn.Domain.EvolutionReport
import Kyyn.Domain.Plugin (pluginName, pluginNameText)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Plumbing.Protocol.Plugin (originShape, originValue, parseOrigin)
import Kyyn.Plumbing.Protocol.EvolutionRecord.Contract (snapshotShape, snapshotValue, restoreSnapshot)
import Kyyn.Plumbing.Protocol.Curation (curationShape, curationValue, parseCuration)
import Kyyn.Plumbing.Protocol.Recipes (recipeShape, legacyRecipeShape, recipeValue, parseRecipe)
import Kyyn.Domain.Curation (recipeId)
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Fact (FactId(..))

recordDocument :: EvolutionId -> RootContract -> RootContract -> EvolutionReport
  -> Either [Diagnostic] (Shape, Value)
recordDocument identity before after (EvolutionReport plugins steps curation) = do
  encoded <- traverse step steps
  pure (recordShape before after,
    object ["version" .= ("5" :: String), "identity" .= evolutionIdName identity, "before" .= snapshotValue before,
      "after" .= snapshotValue after, "steps" .= encoded, "curation" .= curationValue curation,
      "plugins" .= [object ["name" .= pluginNameText name, "before" .= optional originValue old,
        "after" .= optional originValue new, "files" .= map relativeName paths] | PluginChange name old new paths <- plugins]])
  where
    endpoints = [("Before",before),("After",after)]
    collections = collectionNames before after
    step (StepReport (Rationale explanation evidence) changes) = do
      unless (all (`elem` collections) [collection | FactChange collection _ _ _ <- changes])
        (invalid "Report names a collection outside its endpoint schemas")
      grouped <- traverse (\collection -> do
        values <- traverse (\(ident,old,new) -> change ident old new)
          [(ident,old,new) | FactChange name ident old new <- changes, name == collection]
        pure (Key.fromString collection .= values)) collections
      recipes <- traverse (\(ident,old,new) -> do
        _ <- either invalid pure (recipeId ident)
        unless (old /= Nothing || new /= Nothing) (invalid "Recipe change has no value")
        pure (object ["id" .= ident,"before" .= optional recipeValue old,"after" .= optional recipeValue new]))
        [(ident,old,new) | RecipeChange (FactId ident) old new <- changes]
      pure (object ["explanation" .= explanation, "evidence" .= map evidenceValue evidence,
        "changes" .= object grouped, "recipeChanges" .= recipes])
    change (FactId name) old new = do
      unless (old /= Nothing || new /= Nothing) (invalid "Fact change has no value")
      b <- side old
      a <- side new
      pure (object ["id" .= name, "before" .= b, "after" .= a])
    side Nothing = pure (tagged "None" Nothing)
    side (Just (RecordedFact contract value)) = case [tag | (tag,endpoint) <- endpoints, contract == endpoint] of
      tag : _ -> pure (tagged "Some" (Just (tagged tag (Just value))))
      [] -> invalid "Report contains a fact from outside its endpoint schemas"

headerFields :: [(String,Shape)]
headerFields = [("version",Scalar IntegerScalar),("identity",text),("before",snapshotShape),("after",snapshotShape)]

headerShape :: Shape
headerShape = Record headerFields

recordShape :: RootContract -> RootContract -> Shape
recordShape before after = withPlugins (recordShapeWithRecipes (Just recipeShape) before after)

openRecipeRecordShape :: RootContract -> RootContract -> Shape
openRecipeRecordShape before after = withPlugins (previousRecordShape before after)

withPlugins :: Shape -> Shape
withPlugins shape = case shape of
  Record fields -> Record (fields ++ [("plugins",List (Record [("name",text),("before",Optional originShape),
    ("after",Optional originShape),("files",List text)]))])
  _ -> error "Expected record shape"

previousRecordShape :: RootContract -> RootContract -> Shape
previousRecordShape = recordShapeWithRecipes (Just legacyRecipeShape)

legacyRecordShape :: RootContract -> RootContract -> Shape
legacyRecordShape = recordShapeWithRecipes Nothing

recordShapeWithRecipes :: Maybe Shape -> RootContract -> RootContract -> Shape
recordShapeWithRecipes recipe before after = Record (headerFields ++ [("steps",List step),("curation",curationShape)])
  where
    fact collection = Union [(tag, Just (Record [("id",text),("value",shape)])) |
      (tag,contract) <- [("Before",before),("After",after)],
      CollectionContract name _ _ shape <- collectionContracts (rootSchema contract), name == collection]
    change collection = Record [("id",text),("before",Optional (fact collection)),("after",Optional (fact collection))]
    step = Record ([("explanation",text),("evidence",List evidenceShape),
      ("changes",Record [(name,List (change name)) | name <- collectionNames before after])] ++
      [("recipeChanges",List (Record [("id",text),("before",Optional payload),("after",Optional payload)])) | Just payload <- [recipe]])

collectionNames :: RootContract -> RootContract -> [String]
collectionNames before after = sort (nub [name | contract <- [before,after],
  CollectionContract name _ _ _ <- collectionContracts (rootSchema contract)])

decodeHeader :: Value -> Either String (Either [Diagnostic] (EvolutionId, RootContract, RootContract))
decodeHeader = parseEither header

header :: Value -> Parser (Either [Diagnostic] (EvolutionId,RootContract,RootContract))
header = withObject "Evolution record" $ \record -> do
  version <- record .: "version" :: Parser String
  identity <- record .: "identity" >>= either fail pure . evolutionId
  if version `notElem` ["2","3","4","5"] then pure (Left [errorDiagnostic "evolution.record-format"
    "Stored evolution record format is not supported by this kernel"])
  else do
    before <- record .: "before" >>= restoreSnapshot
    after <- record .: "after" >>= restoreSnapshot
    pure ((identity,,) <$> before <*> after)

decodeRecord :: RootContract -> RootContract -> Value -> Either String EvolutionReport
decodeRecord before after = parseEither $ withObject "Evolution record" $ \record -> do
  steps <- record .: "steps" >>= traverse (step [("Before",before),("After",after)])
  curation <- record .: "curation" >>= parseCuration
  plugins <- record .:? "plugins" .!= [] >>= traverse (withObject "Plugin change" $ \fields -> do
    name <- fields .: "name" >>= either fail pure . pluginName
    old <- fields .: "before" >>= parseOptional parseOrigin
    new <- fields .: "after" >>= parseOptional parseOrigin
    unless (old /= Nothing || new /= Nothing) (fail "Plugin change has no package")
    paths <- fields .: "files" >>= traverse (either fail pure . relativePath)
    pure (PluginChange name old new paths))
  pure (EvolutionReport plugins steps curation)
  where
    step :: [(String,RootContract)] -> Value -> Parser StepReport
    step endpoints = withObject "Step" $ \record -> do
      explanation <- record .: "explanation"
      evidence <- record .: "evidence" >>= traverse evidenceRef
      changes <- record .: "changes" >>= withObject "Changes" (\groups ->
        concat <$> traverse (\(collection,values) ->
          parseChanges endpoints (Key.toString collection) values) (sortOn fst (Keys.toList groups)))
      recipes <- record .:? "recipeChanges" .!= [] >>= traverse
        (withObject "RecipeChange" $ \fields -> do
          name <- fields .: "id"
          _ <- either fail pure (recipeId name)
          old <- fields .: "before" >>= parseOptional parseRecipe
          new <- fields .: "after" >>= parseOptional parseRecipe
          unless (old /= Nothing || new /= Nothing) (fail "Recipe change has no value")
          pure (RecipeChange (FactId name) old new))
      pure (StepReport (Rationale explanation evidence) (changes ++ recipes))
    parseChanges endpoints collection values = do
      entries <- parseJSON values
      traverse (withObject "Change" $ \record -> do
        identity <- record .: "id"
        old <- record .: "before" >>= side endpoints identity
        new <- record .: "after" >>= side endpoints identity
        unless (old /= Nothing || new /= Nothing) (fail "Fact change has no value")
        pure (FactChange collection (FactId identity) old new)) entries
    side endpoints identity = withObject "Optional fact" $ \record -> do
      tag <- record .: "tag" :: Parser String
      case tag of
        "None" -> pure Nothing
        "Some" -> record .: "value" >>= withObject "Endpoint fact" (\fact -> do
          endpoint <- fact .: "tag"
          schema <- maybe (fail "Unknown report endpoint") pure (lookup endpoint endpoints)
          value <- fact .: "value"
          actual <- withObject "Fact" (.: "id") value
          unless (identity == actual) (fail "Fact ID disagrees with its change")
          pure (Just (RecordedFact schema value)))
        _ -> fail "Expected Some or None"

text :: Shape
text = Scalar TextScalar

evidenceShape :: Shape
evidenceShape = Record [("producer",text), ("connector",text), ("source",text), ("references",List text)]

evidenceValue :: EvidenceRef -> Value
evidenceValue (EvidenceRef producer connector source references) = object
  ["producer" .= producer, "connector" .= connector, "source" .= source, "references" .= references]

evidenceRef :: Value -> Parser EvidenceRef
evidenceRef = withObject "Evidence" $ \record -> EvidenceRef
  <$> record .: "producer" <*> record .: "connector" <*> record .: "source" <*> record .: "references"

tagged :: String -> Maybe Value -> Value
tagged tag value = object (["tag" .= tag] ++ maybe [] (\v -> ["value" .= v]) value)

optional :: (a -> Value) -> Maybe a -> Value
optional _ Nothing = tagged "None" Nothing
optional encode (Just value) = tagged "Some" (Just (encode value))

parseOptional :: (Value -> Parser a) -> Value -> Parser (Maybe a)
parseOptional parse = withObject "Optional" $ \fields -> do
  tag <- fields .: "tag" :: Parser String
  case tag of
    "None" -> pure Nothing
    "Some" -> Just <$> (fields .: "value" >>= parse)
    _ -> fail "Expected Some or None"

invalid :: String -> Either [Diagnostic] a
invalid = Left . pure . errorDiagnostic "evolution.invalid-report"
