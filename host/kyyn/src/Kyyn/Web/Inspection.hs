module Kyyn.Web.Inspection
  ( InspectionRoute(..), renderInspection, renderInspectionError, inspectionLink ) where

import Control.Monad (forM_, unless)
import Data.Algorithm.Diff (PolyDiff(..), getGroupedDiff)
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
import Kyyn.Domain.Recipe (RecipeDefinition(..), StoredRecipe(..), recipeDefinition)
import Kyyn.Domain.Root (Root(..), RootDefinition(..))
import Kyyn.Domain.Query (QueryDefinition(..), QueryDescriptor(..))
import Kyyn.Domain.Tool (ToolDefinition(..), ToolDescriptor(..))
import Kyyn.Domain.Plugin (MethodName(..))
import Kyyn.Domain.Model (ModelConfiguration(..), ModelProvider(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Domain.Secret (secretNameText)
import Kyyn.Types.Fact (Fact(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Domain.Path (relativeName)
import Kyyn.Domain.SnapshotReport
import Kyyn.Domain.StoredSnapshot (RecordedValue(..), RecordedRecipe(..))
import Kyyn.Domain.Workspace (WorkspaceManifest(..), EvolutionState(..))
import qualified Kyyn.Types.Contract as Contract
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.SchemaMetadata

data InspectionRoute = IndexPage | EvolutionPage EvolutionId | CollectionPage String
  | RecordPage String Text | TypePage String
  | QueryPage String (Maybe Text) | ToolPage String | RecipePage Text | RecipeTypePage Text String

-- Keep routing and data acquisition outside the HTML renderer.
renderInspection :: Maybe EvolutionId -> Either [Diagnostic] SnapshotInspection -> InspectionRoute
  -> [EvolutionSummary] -> Maybe EvolutionInspection -> Maybe DeclarationInspection -> Either [Diagnostic] (Html ())
renderInspection selected snapshot route summaries evolution declaration = do
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
      SnapshotInspection _ _ (Root root _ _ _) _ _ <- snapshot
      target <- case [t | t@(Algebraic _ _ _) <- reachableTypes (rootType (rootSchema root)), haskellType t == name] of
        t:_ -> Right t
        _ -> missing "type" name
      pure (Text.pack name,typeBody (inspectionLink selected . ("types":) . pure . Text.pack) (rootSchema root) target)
    RecipeTypePage recipeName name -> do
      SnapshotInspection _ _ (Root _ _ _ recipes) _ _ <- snapshot
      contract <- case [contract | Fact (FactId actual) (StoredRecipe _ _ contract _) <- recipes, actual == recipeName] of
        [contract] -> Right contract
        _ -> missing "recipe" (Text.unpack recipeName)
      target <- case [typ | typ <- reachableTypes (rootType contract), haskellType typ == name] of
        typ:_ -> Right typ
        _ -> missing "recipe state type" name
      pure (Text.pack name, do
        p_ $ a_ [href_ (inspectionLink selected ["recipes",recipeName])] (toHtml recipeName)
        typeBody (recipeTypeLink selected recipeName) contract target)
    QueryPage name _ -> declared name
    ToolPage name -> declared name
    RecipePage name -> declared (Text.unpack name)
  pure $ document selected snapshot title body
  where
    declared name = do
      current <- snapshot
      case declaration of
        Just value -> Right (Text.pack name,declarationBody selected current value)
        Nothing -> missing "declaration" name
    missing kind name = Left [errorDiagnostic "inspection.unknown" ("Unknown " ++ kind ++ ": " ++ name)]

renderInspectionError :: Maybe EvolutionId -> [Diagnostic] -> Html ()
renderInspectionError selected diagnostics =
  document selected (Left diagnostics) "Page unavailable" (diagnosticsBody diagnostics)

stateLabel :: EvolutionState -> Text
stateLabel Draft = "Draft"
stateLabel Ready = "Ready for review"
stateLabel Accepted = "Accepted"

affordanceLabel :: Affordance -> Text
affordanceLabel Title = "title"
affordanceLabel Timeline = "timeline"
affordanceLabel Badge = "badge"

originLabel :: StepOrigin -> Text
originLabel Authored = "Authored change"
originLabel TargetProjection = "Target schema projection"

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
    link_ [rel_ "stylesheet", href_ "/_inspection/vendor/prism.css"]
    script_ [src_ "/_inspection/vendor/prism.js", defer_ ""] ("" :: Text)
    script_ [src_ "/_inspection/inspection.mjs", type_ "module"] ("" :: Text)
    style_ ("body{font:16px/1.55 system-ui,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#202832}a{color:#245a94}nav{display:flex;gap:1rem}h1{line-height:1.2}table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:.5rem;border-bottom:1px solid #ddd;vertical-align:top}dt{font-weight:600}dd{margin-bottom:1rem}dd,td{overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f4f5f7;padding:1rem}details{margin:1rem 0}summary{cursor:pointer;overflow-wrap:anywhere}pre[class],code[class]{white-space:pre-wrap;overflow-wrap:anywhere}code[class]{text-shadow:none}.flow-viewport{overflow:auto;max-height:65vh;border:1px solid #ddd;margin:1rem 0}.flow-viewport svg{max-width:none!important;display:block}.flow-toolbar{display:flex;gap:.5rem}.flow-viewport [role=button]{cursor:pointer}.flow-viewport [role=button]:focus{outline:2px solid #245a94}#flow-mermaid{max-height:60vh;overflow:auto}.context{color:#556}.comparison{display:grid;grid-template-columns:1fr 1fr;gap:1rem;min-width:0}.comparison>div{min-width:0}pre.diff-added{background:#e5f5e8}pre.diff-removed{background:#fbe7e7}.diff-context pre{color:#667}@media(max-width:700px){.comparison{grid-template-columns:1fr}}" :: Text)
  body_ $ do
    nav_ $ do
      a_ [href_ (inspectionLink selected [])] "Index"
      a_ [href_ "/kb/"] "Views"
      case selected of Nothing -> mempty; Just _ -> a_ [href_ "/"] "Accepted KB"
    p_ [class_ "context"] $ toHtml $ case snapshot of
      Right (SnapshotInspection revision draft _ _ _) -> maybe "Accepted KB" (\i -> "Draft " <> Text.pack (evolutionIdName i) <> " · last checked candidate") draft <>
        " · " <> Text.pack (revisionName revision)
      Left _ -> maybe "Accepted KB" (\i -> "Draft " <> Text.pack (evolutionIdName i)) selected
    h1_ (toHtml title)
    content

indexBody :: Maybe EvolutionId -> Either [Diagnostic] SnapshotInspection -> [EvolutionSummary] -> Html ()
indexBody selected snapshot summaries = do
  h2_ "Evolutions"
  ul_ $ forM_ summaries $ \(EvolutionSummary (EvolutionWorkspace _ identity) (EvolutionName name) state) -> li_ $ do
    a_ [href_ (inspectionLink selected ["evolutions",Text.pack (evolutionIdName identity)])] (toHtml name)
    toHtml (" · " <> stateLabel state)
  case snapshot of
    Left diagnostics -> diagnosticsBody diagnostics
    Right (SnapshotInspection _ _ (Root root _ _ recipes) _ (RootDefinition _ _ _ queries tools _ _)) -> do
      h2_ "Collections"
      ul_ $ forM_ (collectionContracts (rootSchema root)) $ \(CollectionContract name _ _ _) ->
        li_ $ a_ [href_ (inspectionLink selected ["collections",Text.pack name])] (toHtml name)
      h2_ "Types"
      ul_ $ forM_ [haskellType t | t@(Algebraic _ _ _) <- reachableTypes (rootType (rootSchema root))] $ \name ->
        li_ $ a_ [href_ (inspectionLink selected ["types",Text.pack name])] (toHtml name)
      h2_ "Queries"
      ul_ $ forM_ queries $ \(QueryDefinition name description _ _ _ _ _) -> li_ $ do
        a_ [href_ (inspectionLink selected ["queries",Text.pack name])] (toHtml name)
        toHtml (" · " ++ description)
      h2_ "Tools"
      ul_ $ forM_ tools $ \(ToolDefinition (MethodName name) description _ _ _) -> li_ $ do
        a_ [href_ (inspectionLink selected ["tools",Text.pack name])] (toHtml name)
        toHtml (" · " ++ description)
      h2_ "Recipes"
      ul_ $ forM_ recipes $ \(Fact (FactId name) recipe) -> li_ $ do
        a_ [href_ (inspectionLink selected ["recipes",name])] (toHtml name)
        toHtml (case recipeDefinition recipe of OpenRecipe _ _ -> " · Instructions" :: Text; ClosedRecipe _ -> " · Flow")

diagnosticsBody :: [Diagnostic] -> Html ()
diagnosticsBody diagnostics = forM_ diagnostics $ \(Diagnostic _ _ message _) -> p_ (toHtml message)

collection :: SnapshotInspection -> String -> Either [Diagnostic] (RootContract,Shape,[(Text,Value)])
collection (SnapshotInspection _ _ (Root root _ _ _) value _) name = case
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
      titleFields = [field | payload <- payloads, (field,_,_,Title) <- roles (rootSchema root) payload]
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

roles :: CheckedContract -> DataType -> [(Text,Text,Text,Affordance)]
roles root selected = [(field,role,description,affordance) |
  FieldRole record field assigned <- assignments, Algebraic name _ _ <- [selected], record == Text.pack name,
  RoleDecl role description affordance <- declarations, role == assigned]
  where SchemaMetadata declarations assignments _ = metadataOf root

typeBody :: (String -> Text) -> CheckedContract -> DataType -> Html ()
typeBody link root target = do
  let documents = typeFields (Text.pack (haskellType target)) (descriptionOf root)
  case target of
    Algebraic _ _ _ -> mempty
    UnitType -> p_ "No state fields."
    other -> p_ (typeReference link other)
  forM_ [constructors | Algebraic _ _ constructors <- [target]] $ \constructors ->
    forM_ constructors $ \(Constructor name fields) -> do
      h2_ (toHtml name)
      unless (null fields) $ table_ $ do
        thead_ $ tr_ $ th_ "Field" >> th_ "Type" >> th_ "Description"
        tbody_ $ forM_ fields $ \(field,typ) -> tr_ $ do
          td_ (toHtml (fromMaybe "value" field))
          td_ (typeReference link typ)
          td_ $ toHtml $ fromMaybe "" (field >>= (\f -> lookup (Text.pack f) documents))
  forM_ (roles root target) $ \(field,role,description,affordance) ->
    p_ (toHtml (field <> " · " <> role <> " (" <> affordanceLabel affordance <> ") · " <> description))

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
evolutionBody selected snapshot (EvolutionInspection (WorkspaceManifest base _ explanation state _) source report changes) = do
  p_ (toHtml explanation)
  p_ (toHtml (stateLabel state <> " · base " <> Text.pack (revisionName base)))
  p_ $ case source of
    SavedCapture -> "Source and report: saved capture."
    LiveWorkspace -> "Source: live workspace; no checked candidate."
  h2_ "Steps"
  case report of
    Nothing -> p_ "No checked step report."
    Just (EvolutionReport _ steps) -> forM_ (zip [1 :: Int ..] steps) $ \(number,SnapshotStep origin (Rationale why evidence) changed) -> section_ $ do
      h3_ (toHtml (Text.pack (show number) <> " · " <> originLabel origin))
      p_ (toHtml why)
      forM_ evidence evidenceBody
      forM_ changed $ \change -> case change of
        SnapshotFactChange name (FactId identity) before after -> do
          h4_ $ recordLink name identity (name <> "/" <> identity)
          comparison (recorded before) (recorded after)
        SnapshotFieldChange name before after -> h4_ (toHtml name) >> comparison (recorded before) (recorded after)
        SnapshotMembershipChange name before after -> h4_ (toHtml (name <> " membership")) >> comparison (members name <$> before) (members name <$> after)
        SnapshotRecipeChange (FactId name) before after -> h4_ (toHtml ("Recipe " <> name)) >> comparison (recipeBody selected <$> before) (recipeBody selected <$> after)
  h2_ "Source changes"
  if null changes then p_ "No source changes." else forM_ changes $ \(SourceChange path before after) -> details_ $ do
    summary_ (toHtml (relativeName path))
    sourceDiff (Text.isSuffixOf ".hs" (Text.pack (relativeName path)) || Text.isSuffixOf ".lhs" (Text.pack (relativeName path))) (Text.decodeUtf8With lenientDecode <$> before) (Text.decodeUtf8With lenientDecode <$> after)
  where
    recorded = fmap (\(RecordedValue shape value) -> renderValue selected shape value)
    recordLink :: Text -> Text -> Text -> Html ()
    recordLink name identity label = case snapshot >>= (\s -> collection s (Text.unpack name)) of
      Right (_,_,rows) | identity `elem` map fst rows -> a_ [href_ (inspectionLink selected ["records",name,identity])] (toHtml label)
      _ -> toHtml label
    members :: Text -> [FactId] -> Html ()
    members name identities = if null identities then p_ "No records." else
      ul_ $ forM_ identities $ \(FactId identity) -> li_ (recordLink name identity identity)

evidenceBody :: EvidenceRef -> Html ()
evidenceBody (EvidenceRef producer instanceName source references) = details_ $ do
  summary_ "Evidence"
  dl_ $ do
    dt_ "Producer"; dd_ (toHtml producer)
    dt_ "Instance"; dd_ (toHtml instanceName)
    dt_ "Source"; dd_ (toHtml source)
    dt_ "References"; dd_ $ ul_ $ forM_ references (li_ . toHtml)

recipeBody :: Maybe EvolutionId -> RecordedRecipe -> Html ()
recipeBody selected (RecordedRecipe definition (RecordedValue shape value)) = do
  case definition of
    OpenRecipe instructions stateType -> do
      expandableText instructions
      p_ (toHtml ("State type: " <> Text.pack stateType))
    ClosedRecipe (FlowEntryRef flow) -> p_ (toHtml ("Flow: " <> flow))
  h5_ "State"
  renderValue selected shape value

comparison :: Maybe (Html ()) -> Maybe (Html ()) -> Html ()
comparison before after = div_ [class_ "comparison"] $ do
  div_ $ h4_ "Before" >> fromMaybe (p_ "Absent") before
  div_ $ h4_ "After" >> fromMaybe (p_ "Absent") after

sourceDiff :: Bool -> Maybe Text -> Maybe Text -> Html ()
sourceDiff hs Nothing (Just after) = h4_ "Added file" >> pre_ [class_ "diff-added"] (sourceCode hs after)
sourceDiff hs (Just before) Nothing = h4_ "Removed file" >> pre_ [class_ "diff-removed"] (sourceCode hs before)
sourceDiff hs (Just before) (Just after) = do
  -- Keep line endings in the comparison so a missing final newline is visible.
  forM_ (getGroupedDiff (Text.splitOn "\n" before) (Text.splitOn "\n" after)) $ \chunk -> case chunk of
    First removed -> pre_ [class_ "diff-removed"] (sourceCode hs (Text.unlines (map ("- " <>) removed)))
    Second added -> pre_ [class_ "diff-added"] (sourceCode hs (Text.unlines (map ("+ " <>) added)))
    Both unchanged _ -> details_ [class_ "diff-context"] $ do
      summary_ (toHtml (Text.pack (show (length unchanged)) <> " unchanged lines"))
      pre_ (sourceCode hs (Text.unlines unchanged))
sourceDiff _ Nothing Nothing = mempty

sourceCode :: Bool -> Text -> Html ()
sourceCode True text = code_ [class_ "language-haskell"] (toHtml text)
sourceCode False text = toHtml text

declarationBody :: Maybe EvolutionId -> SnapshotInspection -> DeclarationInspection -> Html ()
declarationBody selected (SnapshotInspection _ _ (Root root _ _ _) _ _) declaration = case declaration of
  QueryInspection (QueryDefinition _ _ implementation _ _ _ _) (QueryDescriptor _ description input output) source result -> do
    p_ (toHtml description)
    signature input output
    implementationBody implementation source
    case result of
      Nothing -> p_ "Add an input parameter to the URL to run this query."
      Just value -> h2_ "Result" >> renderValue selected (contractShape output) value
  ToolInspection (ToolDefinition _ _ _ _ implementation) (ToolDescriptor _ description input output) model source -> do
    p_ (toHtml description)
    signature input output
    h2_ "Model"
    case model of
      Nothing -> p_ "No model configured."
      Just (ModelConfiguration provider modelName credential) -> dl_ $ do
        dt_ "Provider"; dd_ $ toHtml (case provider of OpenAI -> "OpenAI" :: Text; Anthropic -> "Anthropic")
        dt_ "Model"; dd_ (toHtml modelName)
        dt_ "Secret reference"; dd_ (toHtml (secretNameText credential))
    implementationBody implementation source
  RecipeInspection name recipe@(StoredRecipe _ stateType contract (CheckedValue _ state)) flow -> do
    case recipeDefinition recipe of
      OpenRecipe instructions _ -> h2_ "Instructions" >> expandableText instructions
      ClosedRecipe (FlowEntryRef entry) -> do
        h2_ "Flow"
        p_ (toHtml entry)
        forM_ flow $ \diagram -> do
          div_ [id_ "recipe-flow"] mempty
          details_ [id_ "flow-source", open_ ""] $ do
            summary_ "Mermaid source"
            pre_ [id_ "flow-mermaid"] (toHtml diagram)
    h2_ "State type"
    a_ [href_ (recipeTypeLink selected name (haskellType (rootType contract)))] (toHtml stateType)
    h2_ "Current saved state"
    if contractShape contract == Record [] then p_ "No state fields." else
      details_ $ do
        summary_ "Expand saved checkpoint"
        renderValue selected (contractShape contract) state
  where
    names = [haskellType typ | typ@(Algebraic _ _ _) <- reachableTypes (rootType (rootSchema root))]
    typeLink :: String -> Html ()
    typeLink name = if name `elem` names
      then a_ [href_ (inspectionLink selected ["types",Text.pack name])] (toHtml name)
      else code_ (toHtml name)
    signature :: CheckedContract -> CheckedContract -> Html ()
    signature input output = dl_ $ do
      dt_ "Input"; dd_ (typeLink (haskellType (rootType input)))
      dt_ "Result"; dd_ (typeLink (haskellType (rootType output)))

implementationBody :: String -> ImplementationSource -> Html ()
implementationBody implementation (ImplementationSource name contents) = do
  h2_ "Implementation"
  p_ (toHtml implementation)
  h3_ (toHtml name)
  case contents of
    Just text -> pre_ $ code_ [class_ "language-haskell"] (toHtml text)
    Nothing -> p_ "This module is supplied by a dependency; its source is not in the captured KB."

expandableText :: Text -> Html ()
expandableText text
  | Text.length text <= 240 = pre_ (toHtml text)
  | otherwise = details_ [class_ "prompt"] $ do
      summary_ (toHtml (Text.take 240 text <> "…"))
      pre_ (toHtml text)

recipeTypeLink :: Maybe EvolutionId -> Text -> String -> Text
recipeTypeLink selected recipeName name = inspectionLink selected ["recipes",recipeName,"types",Text.pack name]

typeReference :: (String -> Text) -> DataType -> Html ()
typeReference link typ = case typ of
  Algebraic _ _ _ -> a_ [href_ (link (haskellType typ))] (toHtml (haskellType typ))
  ListType inner -> toHtml ("[" :: Text) >> typeReference link inner >> toHtml ("]" :: Text)
  OptionalType inner -> toHtml ("Maybe (" :: Text) >> typeReference link inner >> toHtml (")" :: Text)
  _ -> toHtml (haskellType typ)
