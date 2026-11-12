-- | Atomic report encoding. The value union is local to this document and is
-- inferred by Dhall when read; no historical executable or global registry.
module Kyyn.Plumbing.Protocol.SnapshotArchive (encodeSnapshotArchive, decodeSnapshotArchive) where

import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=), (.:), withObject, withArray, toJSON)
import Data.Aeson.Types (Parser, parseEither, parseJSON)
import Data.Foldable (toList)
import Data.List (nub, sortOn)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.ByteString (ByteString)
import Effectful (Eff, (:>))
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution (EvolutionId, evolutionId, evolutionIdName)
import Kyyn.Domain.EvolutionReport (PluginChange(..))
import Kyyn.Domain.SnapshotReport
import Kyyn.Domain.StoredSnapshot
import Kyyn.Domain.Plugin (pluginName, pluginNameText)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, inferValue, encodeValue)
import Kyyn.Plumbing.Protocol.EvolutionRecord.Contract (snapshotShape, snapshotValue, restoreSnapshot)
import Kyyn.Plumbing.Protocol.Recipes (recipeDefinitionShape, recipeDefinitionValue, parseRecipeDefinition)
import Kyyn.Plumbing.Protocol.Plugin (originShape, originValue, parseOrigin)

type Catalogue = [(String,Shape)]

encodeSnapshotArchive :: DhallHandling :> es
  => EvolutionId -> RootContract -> [PluginChange] -> [SnapshotStep] -> Eff es (Either [Diagnostic] ByteString)
encodeSnapshotArchive identity target plugins steps = case catalogue steps of
  Left message -> pure (bad message)
  Right types -> fmap (fmap Text.encodeUtf8) (encodeValue (archiveShape types) (object
    ["identity" .= evolutionIdName identity,
     "target" .= snapshotValue target, "steps" .= map (stepValue types) steps,
     "plugins" .= map pluginValue plugins]))

-- inferValue typechecks the whole document once. The catalogue comes from the
-- inferred value union, including alternatives not used by any current value.
decodeSnapshotArchive :: DhallHandling :> es
  => ByteString -> Eff es (Either [Diagnostic] (EvolutionId,RootContract,[PluginChange],[SnapshotStep]))
decodeSnapshotArchive bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (bad (show problem))
  Right source -> do
    inferred <- inferValue source
    pure $ do
      (shape,value) <- inferred
      types <- either bad Right (archiveCatalogue shape)
      actual <- either bad Right (storageShape shape)
      expected <- either bad Right (storageShape (archiveShape types))
      unless (actual == expected) (bad "Archive type differs from its structural report format")
      result <- either bad Right (parseEither (parseArchive types) value)
      result

catalogue :: [SnapshotStep] -> Either String Catalogue
catalogue steps = do
  shapes <- traverse storageShape [shape | SnapshotStep _ _ changes <- steps,
    change <- changes, RecordedValue shape _ <- changeValues change]
  let ordered = sortOn show (nub shapes)
  pure [("Value" ++ show index,inferredShape shape) | (index,shape) <- zip [0 :: Int ..] ordered]

changeValues :: SnapshotChange -> [RecordedValue]
changeValues change = case change of
  SnapshotFactChange _ _ before after -> present [before,after]
  SnapshotFieldChange _ before after -> present [before,after]
  SnapshotMembershipChange{} -> []
  SnapshotRecipeChange _ before after -> [value | RecordedRecipe _ value <- present [before,after]]
  where present = foldr (maybe id (:)) []

archiveShape :: Catalogue -> Shape
archiveShape types = Record
  [("identity",text),("target",snapshotShape),("plugins",List pluginShape),
   ("steps",List (Record [("origin",Union [("Authored",Nothing),("TargetProjection",Nothing)]),
     ("explanation",text),("evidence",List evidenceShape),("changes",List change)]))]
  where
    value = Union [(name,Just shape) | (name,shape) <- types]
    sides shape = [("before",Optional shape),("after",Optional shape)]
    recipe = Record [("definition",recipeDefinitionShape),("state",value)]
    change = Union [("Fact",Just (Record ([("collection",text),("id",text)] ++ sides value))),
      ("Field",Just (Record (("name",text) : sides value))),
      ("Membership",Just (Record (("collection",text) : sides (List text)))),
      ("Recipe",Just (Record (("id",text) : sides recipe)))]

archiveCatalogue :: Shape -> Either String Catalogue
archiveCatalogue (Record root)
  | Just (List (Record step)) <- lookup "steps" root
  , Just (List (Union changes)) <- lookup "changes" step
  , Just (Just (Record fact)) <- lookup "Fact" changes
  , Just (Optional (Union values)) <- lookup "before" fact = traverse
      (\(name,payload) -> maybe (Left "Archive value alternative has no payload") (Right . (name,)) payload) values
archiveCatalogue _ = Left "Missing inferred report value union"

stepValue :: Catalogue -> SnapshotStep -> Value
stepValue types (SnapshotStep origin (Rationale explanation evidence) changes) = object
  ["origin" .= tagged (case origin of Authored -> "Authored"; TargetProjection -> "TargetProjection") Nothing,
   "explanation" .= explanation,"evidence" .= map evidenceValue evidence,"changes" .= map change changes]
  where
    value (RecordedValue shape payload) = case storageShape shape of
      Right selected -> case [name | (name,candidate) <- types, storageShape candidate == Right selected] of
        [name] -> tagged name (Just payload)
        _ -> error "Missing local archive shape"
      Left problem -> error problem
    recipe (RecordedRecipe definition state) = object ["definition" .= recipeDefinitionValue definition,"state" .= value state]
    sides encode before after = ["before" .= optional encode before,"after" .= optional encode after]
    ids = toJSON . map (\(FactId name) -> name)
    change item = case item of
      SnapshotFactChange collection (FactId ident) before after -> tagged "Fact" (Just (object
        (["collection" .= collection,"id" .= ident] ++ sides value before after)))
      SnapshotFieldChange name before after -> tagged "Field" (Just (object (["name" .= name] ++ sides value before after)))
      SnapshotMembershipChange collection before after -> tagged "Membership" (Just (object
        (["collection" .= collection] ++ sides ids before after)))
      SnapshotRecipeChange (FactId ident) before after -> tagged "Recipe" (Just (object (["id" .= ident] ++ sides recipe before after)))

parseArchive :: Catalogue -> Value -> Parser (Either [Diagnostic] (EvolutionId,RootContract,[PluginChange],[SnapshotStep]))
parseArchive types = withObject "Stored report" $ \fields -> do
  identity <- fields .: "identity" >>= either fail pure . evolutionId
  target <- fields .: "target" >>= restoreSnapshot
  plugins <- fields .: "plugins" >>= list parsePlugin
  steps <- fields .: "steps" >>= list step
  pure ((\contract -> (identity,contract,plugins,steps)) <$> target)
  where
    recorded = withObject "Recorded value" $ \fields -> do
      name <- fields .: "tag"
      shape <- maybe (fail "Unknown local archive alternative") pure (lookup name types)
      RecordedValue shape <$> fields .: "value"
    recipe = withObject "Recorded recipe" $ \fields ->
      RecordedRecipe <$> (fields .: "definition" >>= parseRecipeDefinition) <*> (fields .: "state" >>= recorded)
    step = withObject "Step" $ \fields -> do
      originTag <- fields .: "origin" >>= withObject "Origin" (.: "tag")
      origin <- case originTag :: Text.Text of "Authored" -> pure Authored; "TargetProjection" -> pure TargetProjection; _ -> fail "Unknown step origin"
      reason <- Rationale <$> fields .: "explanation" <*> (fields .: "evidence" >>= list parseEvidence)
      SnapshotStep origin reason <$> (fields .: "changes" >>= list change)
    change = withObject "Change" $ \fields -> do
      kind <- fields .: "tag" :: Parser Text.Text
      payload <- fields .: "value"
      withObject "Change payload" (\details -> case kind of
        "Fact" -> SnapshotFactChange <$> details .: "collection" <*> (FactId <$> details .: "id") <*>
          (details .: "before" >>= parseOptional recorded) <*> (details .: "after" >>= parseOptional recorded)
        "Field" -> SnapshotFieldChange <$> details .: "name" <*>
          (details .: "before" >>= parseOptional recorded) <*> (details .: "after" >>= parseOptional recorded)
        "Membership" -> SnapshotMembershipChange <$> details .: "collection" <*>
          (details .: "before" >>= parseOptional ids) <*> (details .: "after" >>= parseOptional ids)
        "Recipe" -> SnapshotRecipeChange <$> (FactId <$> details .: "id") <*>
          (details .: "before" >>= parseOptional recipe) <*> (details .: "after" >>= parseOptional recipe)
        _ -> fail "Unknown change kind") payload
    ids value = map FactId <$> parseJSON value

pluginShape :: Shape
pluginShape = Record [("name",text),("before",Optional originShape),("after",Optional originShape),("files",List text)]
pluginValue :: PluginChange -> Value
pluginValue (PluginChange name before after paths) = object
  ["name" .= pluginNameText name,"before" .= optional originValue before,"after" .= optional originValue after,
   "files" .= map relativeName paths]
parsePlugin :: Value -> Parser PluginChange
parsePlugin = withObject "Plugin change" $ \fields -> do
  name <- fields .: "name" >>= either fail pure . pluginName
  before <- fields .: "before" >>= parseOptional parseOrigin
  after <- fields .: "after" >>= parseOptional parseOrigin
  paths <- fields .: "files" >>= traverse (either fail pure . relativePath)
  pure (PluginChange name before after paths)

evidenceShape :: Shape
evidenceShape = Record [("producer",text),("connector",text),("source",text),("externalReferences",List text)]
evidenceValue :: EvidenceRef -> Value
evidenceValue (EvidenceRef producer connector source references) = object
  ["producer" .= producer,"connector" .= connector,"source" .= source,"externalReferences" .= references]
parseEvidence :: Value -> Parser EvidenceRef
parseEvidence = withObject "Evidence" $ \fields ->
  EvidenceRef <$> fields .: "producer" <*> fields .: "connector" <*> fields .: "source" <*> fields .: "externalReferences"
optional :: (a -> Value) -> Maybe a -> Value
optional _ Nothing = tagged "None" Nothing
optional encode (Just value) = tagged "Some" (Just (encode value))
parseOptional :: (Value -> Parser a) -> Value -> Parser (Maybe a)
parseOptional parse = withObject "Optional" $ \fields -> do
  tag <- fields .: "tag" :: Parser Text.Text
  case tag of "None" -> pure Nothing; "Some" -> Just <$> (fields .: "value" >>= parse); _ -> fail "Invalid optional tag"
list :: (Value -> Parser a) -> Value -> Parser [a]
list parse = withArray "List" (traverse parse . toList)
tagged :: String -> Maybe Value -> Value
tagged name payload = object (["tag" .= name] ++ maybe [] (\value -> ["value" .= value]) payload)
text :: Shape
text = Scalar TextScalar
bad :: String -> Either [Diagnostic] a
bad = Left . pure . errorDiagnostic "evolution.snapshot-archive"
