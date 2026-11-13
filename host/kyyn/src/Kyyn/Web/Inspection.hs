{-# LANGUAGE OverloadedRecordDot #-}
module Kyyn.Web.Inspection
  ( InspectionRoute(..), renderInspection, renderInspectionError, inspectionLink, connectorFor, localRoute ) where

import qualified Data.Map.Strict as Map
import Kyyn.Domain.Evidence (Evidence(..), EvidencePayload(..), EvidenceId(..), EvidenceFingerprint(..), FetchSummary(..), FetchId(..), FetchReport(..))
import Kyyn.Domain.EvidenceIndex (EvidenceIndex(..))
import Kyyn.Domain.Blob (BlobRef(..), sdkBlobRefType)
import Kyyn.Domain.Plugin (pluginNameText, ConnectorName(..), ConnectorTypeName(..), BindingName(..), PackageIdentity(..), PluginOrigin(..), PluginRepository(..))
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
import Kyyn.Domain.Git (revisionName, gitUrlText, TreePath(..))
import Kyyn.Domain.Output (OutputDefinition(..), SinkReference(..))
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
import Kyyn.Domain.Path (relativeName, scopePath)
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
  | PluginPage Text | PluginTypePage Text Text Text String | OutputPage String | OutputTypePage String Text String
  | ConnectorPage Text Text | EvidencePage Text Text Text | CaptureTypePage Text Text Text String

-- Keep routing and data acquisition outside the HTML renderer.
renderInspection :: Maybe EvolutionId -> Either [Diagnostic] SnapshotInspection -> InspectionRoute
  -> [EvolutionSummary] -> Maybe EvolutionInspection -> Maybe DeclarationInspection -> LocalInspection -> CatalogueInspection -> Either [Diagnostic] (Html ())
renderInspection selected snapshot route summaries evolution declaration local@(LocalInspection _ _ references) catalogue = do
  (title,body) <- case route of
    IndexPage -> Right ("Knowledge base", indexBody selected snapshot summaries >> catalogueIndex selected snapshot catalogue >> localIndex local)
    EvolutionPage identity -> case evolution of
      Just details -> Right ("Evolution " <> Text.pack (evolutionIdName identity), evolutionBody selected snapshot details references)
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
        p_ $ do
          toHtml ("State type for " :: Text)
          a_ [href_ (inspectionLink selected ["recipes",recipeName])] (toHtml recipeName)
        typeBody (recipeTypeLink selected recipeName) contract target)
    ConnectorPage plugin name -> do
      connector <- connectorFor local plugin name
      pure (plugin <> " / " <> name, connectorBody connector)
    EvidencePage plugin name _ -> do
      connector <- connectorFor local plugin name
      case local of
        LocalInspection _ (Just item) _ -> pure (plugin <> " / " <> name, evidenceItemBody connector item)
        _ -> missing "evidence" "item"
    CaptureTypePage plugin name role nameOfType -> do
      connector <- connectorFor local plugin name
      contract <- case role of
        "payload" -> Right (capturePayload connector)
        "report" -> do
          index <- connector.capture
          case index.report of
            Just (FetchReport contract _) -> Right contract
            Nothing -> missing "fetch report" (Text.unpack name)
        _ -> missing "capture contract" (Text.unpack role)
      target <- case [t | t <- reachableTypes (rootType contract), haskellType t == nameOfType] of
        t:_ -> Right t
        _ -> missing "capture type" nameOfType
      pure (Text.pack nameOfType, do
        localNotice
        p_ $ a_ [href_ (connectorLink connector)] "Connector"
        typeBody (captureTypeLink connector role) contract target)
    PluginPage name -> declared (Text.unpack name)
    OutputPage name -> declared name
    PluginTypePage plugin kind role name -> case declaration of
      Just (PluginInspection _ _ _ connectors) -> do
        contract <- case [c | ConnectorDeclarationInspection (ConnectorTypeName actual) _ contracts _ _ <- connectors,
          Text.pack actual == kind, (key,c) <- contracts, Text.pack key == role] of
          [c] -> Right c
          _ -> missing "plugin contract" (Text.unpack role)
        scopedType contract (pluginTypeLink selected plugin kind role) name
      _ -> missing "plugin" (Text.unpack plugin)
    OutputTypePage name role typ -> case declaration of
      Just (OutputInspection _ (QueryDescriptor _ _ input output)) -> do
        contract <- case role of "input" -> Right input; "result" -> Right output; _ -> missing "output contract" (Text.unpack role)
        scopedType contract (outputTypeLink selected name role) typ
      _ -> missing "output" name
    QueryPage name _ -> declared name
    ToolPage name -> declared name
    RecipePage name -> do
      (title,content) <- declared (Text.unpack name)
      pure (title, p_ (a_ [href_ ("/runs?recipe=" <> Text.decodeUtf8 (urlEncode True (Text.encodeUtf8 name)))] "Recorded runs") >> content)
  pure $ document selected snapshot title body
  where
    scopedType contract link name = case [t | t <- reachableTypes (rootType contract), haskellType t == name] of
      t:_ -> Right (Text.pack name,typeBody link contract t)
      _ -> missing "type" name
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
    style_ ("body{font:16px/1.55 system-ui,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#202832}a{color:#245a94}nav{display:flex;gap:1rem}h1{line-height:1.2}table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:.5rem;border-bottom:1px solid #ddd;vertical-align:top}dt{font-weight:600}dd{margin-bottom:1rem}dd,td{overflow-wrap:anywhere}.text-value{white-space:pre-wrap;overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f4f5f7;padding:1rem}details{margin:1rem 0}summary{cursor:pointer;overflow-wrap:anywhere}pre[class],code[class]{white-space:pre-wrap;overflow-wrap:anywhere}code[class]{text-shadow:none}.flow-viewport{overflow:auto;max-height:65vh;border:1px solid #ddd;margin:1rem 0}.flow-viewport svg{max-width:none!important;display:block}.flow-toolbar{display:flex;gap:.5rem}.flow-viewport [role=button]{cursor:pointer}.flow-viewport [role=button]:focus{outline:2px solid #245a94}#flow-mermaid{max-height:60vh;overflow:auto}.context{color:#556}.comparison{display:grid;grid-template-columns:1fr 1fr;gap:1rem;min-width:0}.comparison>div{min-width:0}pre.diff-added{background:#e5f5e8}pre.diff-removed{background:#fbe7e7}.diff-context pre{color:#667}@media(max-width:700px){.comparison{grid-template-columns:1fr}}" :: Text)
  body_ $ do
    nav_ $ do
      a_ [href_ (inspectionLink selected [])] "Index"
      a_ [href_ "/kb/"] "Views"
      a_ [href_ "/runs"] "Runs"
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
      ul_ $ forM_ recipes $ \(Fact (FactId name) recipe@(StoredRecipe _ _ contract _)) -> li_ $ do
        a_ [href_ (inspectionLink selected ["recipes",name])] (toHtml name)
        toHtml (case recipeDefinition recipe of OpenRecipe _ _ -> " · Instructions" :: Text; ClosedRecipe _ -> " · Flow")
        toHtml (" · State: " :: Text)
        let typ = rootType contract
            fullName = haskellType typ
            label = case typ of
              Algebraic typeName [] _ -> Text.takeWhileEnd (/= '.') (Text.pack typeName)
              _ -> Text.pack fullName
        a_ [href_ (recipeTypeLink selected name fullName), title_ (Text.pack fullName)] (toHtml label)

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
  (Scalar (ExactScalar Contract.BlobRefScalar),_) ->
    either (const (toHtml (scalarText value))) (\fields -> renderValue selected fields value) (shapeOf sdkBlobRefType)
  (Scalar TextScalar,String text) -> span_ [class_ "text-value"] (toHtml text)
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

evolutionBody :: Maybe EvolutionId -> Either [Diagnostic] SnapshotInspection -> EvolutionInspection -> [(EvidenceRef,Either [Diagnostic] ())] -> Html ()
evolutionBody selected snapshot (EvolutionInspection (WorkspaceManifest base _ explanation state _) source report changes) references = do
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
      forM_ evidence (evidenceBody references)
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

evidenceBody :: [(EvidenceRef,Either [Diagnostic] ())] -> EvidenceRef -> Html ()
evidenceBody resolved ref@(EvidenceRef producer instanceName source references) = details_ $ do
  summary_ "Evidence"
  dl_ $ do
    dt_ "Producer"; dd_ (toHtml producer)
    dt_ "Instance"; dd_ (toHtml instanceName)
    dt_ "Source"; dd_ $ case lookup ref resolved of
      Just (Right ()) -> a_ [href_ (inspectionLink Nothing ["evidence",producer,instanceName,source])] (toHtml source)
      Just (Left diagnostics) -> toHtml source >> diagnosticsBody diagnostics
      Nothing -> toHtml source
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
  PluginInspection plugin fingerprint origin connectors -> do
    originBody origin
    let PackageIdentity hash = fingerprint
    dl_ $ do dt_ "Package identity"; dd_ (toHtml hash)
    forM_ connectors $ \(ConnectorDeclarationInspection (ConnectorTypeName kind) sink contracts methods instances) -> do
      h2_ (toHtml kind)
      p_ (if sink then "Sink connector" else "Source connector")
      dl_ $ forM_ contracts $ \(role,contract) -> do
        dt_ (toHtml (Text.replace ":" " · " (Text.pack role)))
        dd_ (typeReference (pluginTypeLink selected (Text.pack (pluginNameText plugin)) (Text.pack kind) (Text.pack role)) (rootType contract))
      unless (null methods) $ do
        h3_ "Captured methods"
        dl_ $ forM_ methods $ \(MethodName method,description) -> dt_ (toHtml method) >> dd_ (toHtml description)
      unless (null instances) $ do
        h3_ "Configured instances"
        forM_ instances $ \(ConnectorName name,BindingName binding,CheckedValue _ value) -> do
          h4_ (toHtml name)
          p_ $ toHtml ("Binding: " ++ binding)
          case lookup "configuration" contracts of
            Just contract -> renderValue selected (contractShape contract) value
            Nothing -> mempty
          unless sink $ p_ $ a_ [href_ (inspectionLink Nothing ["connectors",Text.pack (pluginNameText plugin),Text.pack name])] "Local evidence"
  OutputInspection (OutputDefinition name description query (SinkReference plugin (ConnectorName instanceName) (MethodName method))) (QueryDescriptor _ _ input output) -> do
    p_ (toHtml description)
    dl_ $ do
      dt_ "Renderer"; dd_ $ a_ [href_ (inspectionLink selected ["queries",Text.pack query])] (toHtml query)
      dt_ "Input"; dd_ (typeReference (outputTypeLink selected name "input") (rootType input))
      dt_ "Result"; dd_ (typeReference (outputTypeLink selected name "result") (rootType output))
      dt_ "Sink"; dd_ $ do
        a_ [href_ (inspectionLink selected ["plugins",Text.pack (pluginNameText plugin)])] (toHtml (pluginNameText plugin))
        toHtml (" / " ++ instanceName ++ " / " ++ method)
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
        summary_ "State"
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

localRoute :: InspectionRoute -> Bool
localRoute ConnectorPage{} = True
localRoute EvidencePage{} = True
localRoute CaptureTypePage{} = True
localRoute _ = False

connectorFor :: LocalInspection -> Text -> Text -> Either [Diagnostic] ConnectorInspection
connectorFor (LocalInspection result _ _) plugin name = do
  connectors <- result
  case [c | c <- connectors, Text.pack (pluginNameText c.plugin) == plugin,
    let ConnectorName actual = c.name, Text.pack actual == name] of
    [c] -> Right c
    _ -> Left [errorDiagnostic "inspection.unknown" "Unknown source connector instance"]

localNotice :: Html ()
localNotice = p_ [class_ "context"] "Local capture · accepted connector configuration"

connectorLink :: ConnectorInspection -> Text
connectorLink c = let ConnectorName name = c.name
  in inspectionLink Nothing ["connectors",Text.pack (pluginNameText c.plugin),Text.pack name]

captureTypeLink :: ConnectorInspection -> Text -> String -> Text
captureTypeLink c role name = connectorLink c <> "/types/" <> role <> "/" <> Text.decodeUtf8 (urlEncode True (Text.encodeUtf8 (Text.pack name)))

itemLink :: ConnectorInspection -> Text -> Text
itemLink c key = let ConnectorName name = c.name
  in inspectionLink Nothing ["evidence",Text.pack (pluginNameText c.plugin),Text.pack name,key]

capturePayload :: ConnectorInspection -> CheckedContract
capturePayload c = either (const c.payloadContract) (\index -> index.payloadContract) c.capture

localIndex :: LocalInspection -> Html ()
localIndex (LocalInspection result _ _) = do
  h2_ "Connectors"
  localNotice
  case result of
    Left diagnostics -> diagnosticsBody diagnostics
    Right [] -> p_ "No source connectors configured."
    Right connectors -> ul_ $ forM_ connectors $ \c -> li_ $ do
      let ConnectorName name = c.name; ConnectorTypeName kind = c.kind
      a_ [href_ (connectorLink c)] (toHtml (pluginNameText c.plugin ++ " / " ++ name))
      toHtml (" · " ++ kind)
      case c.capture of
        Left diagnostics -> diagnosticsBody diagnostics
        Right index -> fetchSummaryBody False index.latest

fetchSummaryBody :: Bool -> FetchSummary -> Html ()
fetchSummaryBody detailed (FetchSummary (FetchId identity) time added updated removed options) = do
  p_ (toHtml (time ++ " · " ++ show added ++ " added · " ++ show updated ++ " updated · " ++ show removed ++ " removed"))
  if detailed then do
    p_ (toHtml ("Fetch: " ++ identity))
    h3_ "Supplied options"
    maybe (p_ "None supplied.") (pre_ . toHtml) options
  else mempty

connectorBody :: ConnectorInspection -> Html ()
connectorBody c = do
  localNotice
  let ConnectorTypeName kind = c.kind; BindingName binding = c.binding; PackageIdentity identity = c.package
  dl_ $ do
    dt_ "Connector type"; dd_ (toHtml kind)
    dt_ "Binding"; dd_ (toHtml binding)
    dt_ "Producer package"; dd_ (toHtml identity)
  h2_ "Configuration"
  let CheckedValue _ configuration = c.configuration
  renderValue Nothing (contractShape c.configurationContract) configuration
  h2_ "Payload type"
  let name = haskellType (rootType (capturePayload c))
  a_ [href_ (captureTypeLink c "payload" name)] (toHtml name)
  h2_ "Latest fetch"
  case c.capture of
    Left diagnostics -> diagnosticsBody diagnostics
    Right index -> do
      fetchSummaryBody True index.latest
      forM_ index.report $ \(FetchReport contract (CheckedValue _ value)) -> do
        h2_ "Fetch report"
        let reportType = haskellType (rootType contract)
        p_ $ a_ [href_ (captureTypeLink c "report" reportType)] (toHtml reportType)
        renderValue Nothing (contractShape contract) value
      h2_ "Evidence"
      if Map.null index.items then p_ "No captured items." else table_ $ do
        thead_ $ tr_ $ th_ "Item" >> th_ "Fingerprint" >> th_ "Payload"
        tbody_ $ forM_ (Map.toAscList index.items) $ \(key,Evidence (EvidenceFingerprint fingerprint) _ payload) -> tr_ $ do
          td_ $ a_ [href_ (itemLink c key)] (toHtml key)
          td_ (toHtml fingerprint)
          td_ (toHtml (case payload of Available _ -> "Available" :: Text; Truncated -> "Truncated"))

evidenceItemBody :: ConnectorInspection -> EvidenceItemInspection -> Html ()
evidenceItemBody c (EvidenceItemInspection (EvidenceId key) (Evidence (EvidenceFingerprint fingerprint) refs payload) blobs) = do
  localNotice
  p_ $ a_ [href_ (connectorLink c)] "Connector and latest fetch"
  h2_ (toHtml key)
  dl_ $ do
    dt_ "Fingerprint"; dd_ (toHtml fingerprint)
    dt_ "Source references"; dd_ $ ul_ $ forM_ refs (li_ . toHtml)
  h2_ "Payload"
  case payload of
    Truncated -> p_ "Payload no longer retained locally."
    Available (CheckedValue _ value) -> renderValue Nothing (contractShape (capturePayload c)) value
  unless (null blobs) $ do
    h2_ "Blobs"
    forM_ blobs $ \(BlobRef digest size media name) -> dl_ $ do
      dt_ "Name"; dd_ (toHtml (fromMaybe "Unnamed" name))
      dt_ "Bytes"; dd_ (toHtml (show size))
      dt_ "Media type"; dd_ (toHtml media)
      dt_ "SHA-256"; dd_ (toHtml digest)

pluginTypeLink :: Maybe EvolutionId -> Text -> Text -> Text -> String -> Text
pluginTypeLink selected plugin kind role name = inspectionLink selected ["plugins",plugin,"types",kind,role,Text.pack name]

outputTypeLink :: Maybe EvolutionId -> String -> Text -> String -> Text
outputTypeLink selected output role name = inspectionLink selected ["outputs",Text.pack output,"types",role,Text.pack name]

originBody :: PluginOrigin -> Html ()
originBody (PluginOrigin repository path revision) = dl_ $ do
  dt_ "Repository"; dd_ $ toHtml $ case repository of
    LocalRepository scope -> scopePath scope
    RemoteRepository url -> gitUrlText url
  dt_ "Package path"; dd_ $ toHtml $ case path of WholeTree -> "."; Subtree p -> relativeName p
  dt_ "Pinned revision"; dd_ (toHtml (revisionName revision))

catalogueIndex :: Maybe EvolutionId -> Either [Diagnostic] SnapshotInspection -> CatalogueInspection -> Html ()
catalogueIndex selected snapshot (CatalogueInspection configuration) = do
  h2_ "Plugins"
  case configuration of
    Left diagnostics -> diagnosticsBody diagnostics
    Right (ConfigurationInspection plugins) -> do
      ul_ $ forM_ plugins $ \(plugin,_) -> li_ $
        a_ [href_ (inspectionLink selected ["plugins",Text.pack (pluginNameText plugin)])] (toHtml (pluginNameText plugin))
  case snapshot of
    Right (SnapshotInspection _ _ _ _ (RootDefinition _ _ _ _ _ _ outputs)) -> do
      h2_ "Outputs"
      ul_ $ forM_ outputs $ \(OutputDefinition name description _ _) -> li_ $ do
        a_ [href_ (inspectionLink selected ["outputs",Text.pack name])] (toHtml name)
        toHtml (" · " ++ description)
    Left _ -> mempty
