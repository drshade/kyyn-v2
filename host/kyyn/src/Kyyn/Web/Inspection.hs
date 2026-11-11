module Kyyn.Web.Inspection
  ( InspectionRoute(..), renderInspection, inspectionLink ) where

import Control.Monad (forM_)
import Data.Aeson (Value(..), encode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString.Lazy as Lazy
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Text.Encoding.Error (lenientDecode)
import Lucid
import Network.HTTP.Types (urlEncode)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic(..), errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport (EvolutionReport(..))
import Kyyn.Domain.Git (revisionName)
import Kyyn.Domain.Inspection
import Kyyn.Domain.Path (relativeName)
import Kyyn.Domain.SnapshotReport
import Kyyn.Domain.StoredSnapshot (RecordedValue(..))
import Kyyn.Domain.Workspace (WorkspaceManifest(..))
import qualified Kyyn.Types.Contract as Contract
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.SchemaMetadata

data InspectionRoute = IndexPage | EvolutionPage EvolutionId | CollectionPage String
  | RecordPage String Text | TypePage String

-- Keep routing and data acquisition outside the HTML renderer.
renderInspection :: Maybe EvolutionId -> Either [Diagnostic] SnapshotInspection -> InspectionRoute
  -> [EvolutionSummary] -> Maybe EvolutionInspection -> Either [Diagnostic] (Html ())
renderInspection selected snapshot route summaries evolution = do
  (title,body) <- case route of
    IndexPage -> Right ("Knowledge base", indexBody selected snapshot summaries)
    EvolutionPage identity -> case evolution of
      Just details -> Right ("Evolution " <> Text.pack (evolutionIdName identity), evolutionBody selected snapshot details)
      Nothing -> missing "evolution" (evolutionIdName identity)
    CollectionPage name -> do
      current <- snapshot
      (contract,shape,rows) <- collection current name
      pure (Text.pack name, collectionBody selected contract name shape rows)
    RecordPage name identity -> do
      current <- snapshot
      (_,shape,rows) <- collection current name
      value <- maybe (missing "record" (name ++ "/" ++ Text.unpack identity)) Right (lookup identity rows)
      pure (identity, do
        p_ $ a_ [href_ (inspectionLink selected ["collections",Text.pack name])] (toHtml name)
        renderValue selected shape value)
    TypePage name -> do
      SnapshotInspection _ _ root _ <- snapshot
      target <- case [t | t@(Algebraic _ _ _) <- reachableTypes (rootType (rootSchema root)), haskellType t == name] of
        t:_ -> Right t
        _ -> missing "type" name
      pure (Text.pack name,typeBody selected root target)
  pure $ document selected snapshot title body
  where missing kind name = Left [errorDiagnostic "inspection.unknown" ("Unknown " ++ kind ++ ": " ++ name)]

inspectionLink :: Maybe EvolutionId -> [Text] -> Text
inspectionLink selected segments = "/" <> Text.intercalate "/" (map escaped segments) <>
  maybe "" (\identity -> "?evolution=" <> escaped (Text.pack (evolutionIdName identity))) selected
  where escaped = Text.decodeUtf8 . urlEncode True . Text.encodeUtf8

document :: Maybe EvolutionId -> Either [Diagnostic] SnapshotInspection -> Text -> Html () -> Html ()
document selected snapshot title content = doctypehtml_ $ do
  head_ $ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    title_ (toHtml title)
    style_ ("body{font:16px/1.55 system-ui,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#202832}a{color:#245a94}nav{display:flex;gap:1rem}h1{line-height:1.2}table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:.5rem;border-bottom:1px solid #ddd;vertical-align:top}dt{font-weight:600}dd{margin-bottom:1rem}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f4f5f7;padding:1rem}details{margin:1rem 0}.context{color:#556}.comparison{display:grid;grid-template-columns:1fr 1fr;gap:1rem;min-width:0}.comparison>div{min-width:0}@media(max-width:700px){.comparison{grid-template-columns:1fr}}" :: Text)
  body_ $ do
    nav_ $ do
      a_ [href_ (inspectionLink selected [])] "Index"
      a_ [href_ "/kb/"] "Views"
      case selected of Nothing -> mempty; Just _ -> a_ [href_ "/"] "Accepted KB"
    p_ [class_ "context"] $ toHtml $ case snapshot of
      Right (SnapshotInspection revision draft _ _) -> maybe "Accepted KB" (\i -> "Draft " <> Text.pack (evolutionIdName i) <> " · last checked candidate") draft <>
        " · " <> Text.pack (revisionName revision)
      Left _ -> maybe "Accepted KB" (\i -> "Draft " <> Text.pack (evolutionIdName i)) selected
    h1_ (toHtml title)
    content

indexBody :: Maybe EvolutionId -> Either [Diagnostic] SnapshotInspection -> [EvolutionSummary] -> Html ()
indexBody selected snapshot summaries = do
  h2_ "Evolutions"
  ul_ $ forM_ summaries $ \(EvolutionSummary (EvolutionWorkspace _ identity) (EvolutionName name) state) -> li_ $ do
    a_ [href_ (inspectionLink selected ["evolutions",Text.pack (evolutionIdName identity)])] (toHtml name)
    toHtml (" · " ++ show state)
  case snapshot of
    Left diagnostics -> diagnosticsBody diagnostics
    Right (SnapshotInspection _ _ root _) -> do
      h2_ "Collections"
      ul_ $ forM_ (collectionContracts (rootSchema root)) $ \(CollectionContract name _ _ _) ->
        li_ $ a_ [href_ (inspectionLink selected ["collections",Text.pack name])] (toHtml name)
      h2_ "Types"
      ul_ $ forM_ [haskellType t | t@(Algebraic _ _ _) <- reachableTypes (rootType (rootSchema root))] $ \name ->
        li_ $ a_ [href_ (inspectionLink selected ["types",Text.pack name])] (toHtml name)

diagnosticsBody :: [Diagnostic] -> Html ()
diagnosticsBody diagnostics = forM_ diagnostics $ \(Diagnostic _ _ message _) -> p_ (toHtml message)

collection :: SnapshotInspection -> String -> Either [Diagnostic] (RootContract,Shape,[(Text,Value)])
collection (SnapshotInspection _ _ root value) name = case
  [c | c@(CollectionContract actual _ _ _) <- collectionContracts (rootSchema root), actual == name] of
    [CollectionContract _ field _ shape] -> case value of
      Object fields | Just (Array values) <- Keys.lookup (Key.fromString field) fields ->
        Right (root,shape,[(identity,payload) | Object entry <- toList values,
          Just (String identity) <- [Keys.lookup "id" entry], Just payload <- [Keys.lookup "value" entry]])
      _ -> Left [errorDiagnostic "inspection.collection" "Collection is missing from the stored snapshot"]
    _ -> Left [errorDiagnostic "inspection.unknown" ("Unknown collection: " ++ name)]

collectionBody :: Maybe EvolutionId -> RootContract -> String -> Shape -> [(Text,Value)] -> Html ()
collectionBody selected root name _ rows = do
  let payloads = [payload | CollectionContract actual _ payload _ <- collectionContracts (rootSchema root), actual == name]
      titleFields = [field | payload <- payloads, (field,_,_,Title) <- roles root payload]
      title value = case (titleFields,value) of
        (field:_,Object fields) -> maybe "" scalarText (Keys.lookup (Key.fromText field) fields)
        _ -> ""
  forM_ payloads $ \payload -> p_ $ a_ [href_ (inspectionLink selected ["types",Text.pack (haskellType payload)])] (toHtml (haskellType payload))
  if null rows then p_ "No records." else table_ $ do
    thead_ $ tr_ $ th_ "Record" >> th_ "Title"
    tbody_ $ forM_ rows $ \(identity,value) -> tr_ $ do
      td_ $ a_ [href_ (inspectionLink selected ["records",Text.pack name,identity])] (toHtml identity)
      td_ (toHtml (title value))

renderValue :: Maybe EvolutionId -> Shape -> Value -> Html ()
renderValue selected shape value = case (shape,value) of
  (Record fields,Object values) -> dl_ $ forM_ fields $ \(name,inner) -> do
    dt_ (toHtml name)
    dd_ $ maybe (toHtml ("Unavailable" :: Text)) (renderValue selected inner) (Keys.lookup (Key.fromString name) values)
  (List inner,Array values) -> ul_ $ forM_ (toList values) (li_ . renderValue selected inner)
  (Optional inner,Object fields) -> case Keys.lookup "value" fields of
    Just payload -> renderValue selected inner payload
    Nothing -> toHtml ("None" :: Text)
  (Union arms,Object fields) -> do
    let tag = fromMaybe "" (Keys.lookup "tag" fields >>= asText)
    toHtml tag
    case (lookup (Text.unpack tag) arms,Keys.lookup "value" fields) of
      (Just (Just inner),Just payload) -> renderValue selected inner payload
      _ -> mempty
  (Reference target,String identity) -> a_ [href_ (inspectionLink selected ["records",Text.pack target,identity])] (toHtml identity)
  _ -> toHtml (scalarText value)

scalarText :: Value -> Text
scalarText (String value) = value
scalarText (Object fields) | Just (String "Some") <- Keys.lookup "tag" fields,
  Just value <- Keys.lookup "value" fields = scalarText value
scalarText value = Text.decodeUtf8 (Lazy.toStrict (encode value))
asText :: Value -> Maybe Text
asText (String value) = Just value
asText _ = Nothing

roles :: RootContract -> DataType -> [(Text,Text,Text,Affordance)]
roles root selected = [(field,role,description,affordance) |
  FieldRole record field assigned <- assignments, Algebraic name _ _ <- [selected], record == Text.pack name,
  RoleDecl role description affordance <- declarations, role == assigned]
  where SchemaMetadata declarations assignments _ = metadataOf (rootSchema root)

typeBody :: Maybe EvolutionId -> RootContract -> DataType -> Html ()
typeBody selected root target = do
  let documents = typeFields (Text.pack (haskellType target)) (descriptionOf (rootSchema root))
  forM_ [constructors | Algebraic _ _ constructors <- [target]] $ \constructors ->
    forM_ constructors $ \(Constructor name fields) -> do
      h2_ (toHtml name)
      table_ $ do
        thead_ $ tr_ $ th_ "Field" >> th_ "Type" >> th_ "Description"
        tbody_ $ forM_ fields $ \(field,typ) -> tr_ $ do
          td_ (toHtml (fromMaybe "value" field))
          td_ $ case typ of
            Algebraic _ _ _ -> a_ [href_ (inspectionLink selected ["types",Text.pack (haskellType typ)])] (toHtml (haskellType typ))
            _ -> toHtml (haskellType typ)
          td_ $ toHtml $ fromMaybe "" (field >>= (\f -> lookup (Text.pack f) documents))
  forM_ (roles root target) $ \(field,role,description,affordance) ->
    p_ (toHtml (field <> " · " <> role <> " (" <> Text.pack (show affordance) <> ") · " <> description))

-- Documentation is taken from the checked contract, not parsed from source.
typeFields :: Text -> Contract.Description -> [(Text,Text)]
typeFields wanted description = case description of
  Contract.NamedDescription _ inner
    | Text.pack (haskellType (descriptionType description)) == wanted -> fields inner
    | otherwise -> typeFields wanted inner
  Contract.RecordDescription _ _ entries -> concat [typeFields wanted inner | Contract.FieldDescription _ _ inner <- entries]
  Contract.SumDescription cases -> concat [typeFields wanted inner | Contract.CaseDescription _ _ _ entries <- cases, Contract.FieldDescription _ _ inner <- entries]
  Contract.ListDescription inner -> typeFields wanted inner
  Contract.OptionalDescription inner -> typeFields wanted inner
  Contract.CheckedDescription _ inner -> typeFields wanted inner
  Contract.DocumentedDescription _ inner -> typeFields wanted inner
  _ -> []
  where
    fields (Contract.RecordDescription _ _ entries) = [(name,doc) | Contract.FieldDescription name doc _ <- entries]
    fields (Contract.SumDescription cases) = [(name,doc) | Contract.CaseDescription _ _ _ entries <- cases, Contract.FieldDescription name doc _ <- entries]
    fields (Contract.DocumentedDescription _ inner) = fields inner
    fields (Contract.CheckedDescription _ inner) = fields inner
    fields inner = typeFields wanted inner

evolutionBody :: Maybe EvolutionId -> Either [Diagnostic] SnapshotInspection -> EvolutionInspection -> Html ()
evolutionBody selected snapshot (EvolutionInspection (WorkspaceManifest base _ explanation state _) captured report changes) = do
  p_ (toHtml explanation)
  p_ (toHtml (show state ++ " · base " ++ revisionName base))
  p_ (if captured then "Source and report: saved capture." else "Source: live workspace; no checked candidate.")
  h2_ "Steps"
  case report of
    Nothing -> p_ "No checked step report."
    Just (EvolutionReport _ steps) -> forM_ (zip [1 :: Int ..] steps) $ \(number,SnapshotStep origin (Rationale why evidence) changed) -> section_ $ do
      h3_ (toHtml (show number ++ " · " ++ show origin))
      p_ (toHtml why)
      forM_ evidence (p_ . toHtml . show)
      forM_ changed $ \change -> case change of
        SnapshotFactChange name (FactId identity) before after -> do
          h4_ $ case snapshot >>= (\s -> collection s (Text.unpack name)) of
            Right (_,_,rows) | identity `elem` map fst rows -> a_ [href_ (inspectionLink selected ["records",name,identity])] (toHtml (name <> "/" <> identity))
            _ -> toHtml (name <> "/" <> identity)
          comparison (recorded before) (recorded after)
        SnapshotFieldChange name before after -> h4_ (toHtml name) >> comparison (recorded before) (recorded after)
        SnapshotMembershipChange name before after -> h4_ (toHtml (name <> " membership")) >> comparison (showValue before) (showValue after)
        SnapshotRecipeChange (FactId name) before after -> h4_ (toHtml ("Recipe " <> name)) >> comparison (showValue before) (showValue after)
  h2_ "Source changes"
  if null changes then p_ "No source changes." else forM_ changes $ \(SourceChange path before after) -> details_ $ do
    summary_ (toHtml (relativeName path))
    comparison (Text.decodeUtf8With lenientDecode <$> before) (Text.decodeUtf8With lenientDecode <$> after)
  where
    recorded = fmap (\(RecordedValue _ value) -> scalarText value)
    showValue :: Show a => Maybe a -> Maybe Text
    showValue = fmap (Text.pack . show)

comparison :: Maybe Text -> Maybe Text -> Html ()
comparison before after = div_ [class_ "comparison"] $ do
  div_ $ h4_ "Before" >> pre_ (toHtml (fromMaybe "Absent" before))
  div_ $ h4_ "After" >> pre_ (toHtml (fromMaybe "Absent" after))
