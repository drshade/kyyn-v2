{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.RootStore (runRootStore) where

import Control.Monad (unless, forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE, withExceptT)
import Data.Aeson (Value(..), object, (.=), toJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.Foldable (toList)
import Data.List (nub, sort, isPrefixOf, stripPrefix)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Numeric (showHex)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract
import Kyyn.Domain.Curation (checkRecipes, emptyCurationRegister, curationEntries)
import qualified Kyyn.Types.KnowledgeBase as Value
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Porcelain.Protocol.CurationPersistence (encodeRegister, decodeRegister)
import Kyyn.Porcelain.Protocol.RecipePersistence (encodeRecipes, decodeRecipes)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic(..), DiagnosticLocation(..), errorDiagnostic)
import Kyyn.Domain.Path (RelativePath, relativePath, relativeName)
import Kyyn.Domain.Root
import Kyyn.Domain.Query (QueryDefinition(..), QueryDescriptor(..))
import Kyyn.Domain.Tool (ToolDefinition(..))
import Kyyn.Domain.Plugin (methodName, qualifiedTypeName)
import Kyyn.Domain.Example (Example(..), ExampleRequirement(..))
import Kyyn.Domain.FileTree
import qualified Kyyn.Plumbing.Capability.DhallHandling as Dhall
import Kyyn.Porcelain.Capability.RootStore (RootStore(..))
import Kyyn.Porcelain.Protocol.ModelConfiguration (readModelConfiguration)
import Kyyn.Porcelain.Validated (validatedValue)

runRootStore :: Dhall.DhallHandling :> es => Eff (RootStore : es) a -> Eff es a
runRootStore = interpret $ \_ -> \case
  ReadRootCuration tree -> decodeRegister (lookup curationLocation (files tree))
  ReadRootRecipes tree -> decodeRecipes (lookup recipesLocation (files tree))
  ReadRootDefinition code -> runExceptT $ do
    _ <- ExceptT (readModelConfiguration code)
    manifest <- withExceptT (map manifestDiagnostic) $ decodeFile code "kb.dhall"
      (Record ([(name, Scalar TextScalar) | name <- ["schemaType", "schemaMetadata", "validator"]] ++
        [("queries", List (Record [(name, Scalar TextScalar) | name <-
          ["name", "description", "implementation", "inputType", "inputMetadata", "resultType", "resultMetadata"]])),
         ("tools", List (Record [(name, Scalar TextScalar) | name <-
          ["name", "description", "implementation", "inputType", "resultType"]]))])) >>= record
    typeName <- field "schemaType" manifest >>= text
    metadataName <- field "schemaMetadata" manifest >>= text
    validatorName <- field "validator" manifest >>= text
    ensure (not (Text.null validatorName)) "No semantic validator declared in kb.dhall"
    declarations <- field "queries" manifest >>= list >>= traverse (\value -> do
      fields <- record value
      let get name = Text.unpack <$> (field name fields >>= text)
      QueryDefinition <$> get "name" <*> get "description" <*> get "implementation" <*>
        get "inputType" <*> get "inputMetadata" <*> get "resultType" <*> get "resultMetadata")
    let names = [name | QueryDefinition name _ _ _ _ _ _ <- declarations]
    ensure (all (not . null) names && length names == length (nub names)) "Query names must be nonempty and unique"
    tools <- field "tools" manifest >>= list >>= traverse (\value -> do
      fields <- record value
      let get name = Text.unpack <$> (field name fields >>= text)
      ToolDefinition <$> (get "name" >>= liftChecked . methodName) <*> get "description"
        <*> (get "inputType" >>= liftChecked . qualifiedTypeName)
        <*> (get "resultType" >>= liftChecked . qualifiedTypeName) <*> get "implementation")
    let toolNames = [name | ToolDefinition name _ _ _ _ <- tools]
    ensure (length toolNames == length (nub toolNames)) "Tool names must be unique"
    authored <- traverse (\(name,bytes) -> do
      path <- liftChecked (relativePath name)
      pure (path,bytes)) [(name,bytes) | (path,bytes) <- files code, Just name <- [stripPrefix "src/" (relativeName path)]]
    sources <- liftChecked (fileTree authored)
    pure (RootDefinition (Text.unpack typeName) (Text.unpack metadataName) (Text.unpack validatorName) declarations tools sources)
  CheckRootValue selected value -> runExceptT $ do
    let contract = rootSchema selected
    _ <- ExceptT (Dhall.encodeValue (contractShape contract) value)
    pure (CheckedValue (contractId contract) value)
  MaterializeRoot contract code checked -> runExceptT (materialize contract code checked)
  LoadRootValueForChecking root -> runExceptT (loadValue root)
  ReadCollection checked name -> runExceptT $ do
    let root@(Root selected _ _ _ _) = validatedValue checked
    collection <- case [c | c@(CollectionContract actual _ _ _) <- collectionContracts (rootSchema selected), actual == name] of
      [c] -> pure c
      _ -> throwE [errorDiagnostic "fact.collection-unknown" ("Unknown collection: " ++ name)]
    CheckedValue _ value <- loadValue root
    let CollectionContract _ rootField _ _ = collection
    members <- record value >>= field rootField >>= list
    forM members $ \member -> do
      fields <- record member
      identity <- field "id" fields >>= text
      payload <- field "value" fields
      pure (Fact (FactId (Text.unpack identity)) payload)
  ReadExamples (Root _ _ code _ _) descriptors -> runExceptT (loadExamples code descriptors)
  EncodeExample example -> runExceptT (saveExample example)
  ExportRootFiles checked -> runExceptT $ do
    let Root _ facts code curation recipes = validatedValue checked
    recipeBytes <- ExceptT (encodeRecipes recipes)
    progress <- if null (curationEntries curation) then pure [] else do
      bytes <- ExceptT (encodeRegister curation)
      pure [(curationLocation,bytes)]
    liftChecked (fileTree ((recipesLocation,recipeBytes) : progress ++ files facts ++ files code))

type Result es = ExceptT [Diagnostic] (Eff es)

manifestDiagnostic :: Diagnostic -> Diagnostic
manifestDiagnostic (Diagnostic severity code message location) = Diagnostic severity code
  (message ++ "\nCheck kb.dhall. If this KB has no tools, include: tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }") location

problem :: String -> Result es a
problem = throwE . pure . errorDiagnostic "root.storage"

ensure :: Bool -> String -> Result es ()
ensure condition message = unless condition (problem message)

liftChecked :: Either String a -> Result es a
liftChecked = either problem pure

rootFields :: CheckedContract -> Result es [(String, Shape)]
rootFields contract = case contractShape contract of
  Record fields -> pure fields
  _ -> problem "Root contract is not a record"

record :: Value -> Result es (Keys.KeyMap Value)
record (Object values) = pure values
record _ = problem "Expected record"

field :: String -> Keys.KeyMap Value -> Result es Value
field name = maybe (problem ("Missing field: " ++ name)) pure . Keys.lookup (Key.fromString name)

list :: Value -> Result es [Value]
list (Array values) = pure (toList values)
list _ = problem "Expected list"

text :: Value -> Result es Text
text (String value) = pure value
text _ = problem "Expected text"

factShape :: Shape -> Shape
factShape payload = Record [("id", Scalar TextScalar), ("value", payload)]

collectionDirectory :: String -> String
collectionDirectory name = relativeName factsLocation ++ "/" ++ encoded (Text.pack name)

factName :: String -> Text -> String
factName collection identity = collectionDirectory collection ++ "/" ++ encoded identity ++ ".dhall"

indexName :: String -> String
indexName collection = collectionDirectory collection ++ "/index.dhall"

encoded :: Text -> String
encoded value
  | not (Text.null value) && Text.all safe value && value `notElem` reserved = Text.unpack value
  | otherwise = '~' : concatMap hex (Bytes.unpack (Text.encodeUtf8 value))
  where
    safe c = c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_'
    reserved = ["index", "con", "prn", "aux", "nul"] ++
      [prefix <> Text.pack (show n) | prefix <- ["com", "lpt"], n <- [1 :: Int .. 9]]
    hex byte = let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits

encodeFile :: Dhall.DhallHandling :> es => String -> Shape -> Value -> Result es (RelativePath, Bytes.ByteString)
encodeFile name shape value = do
  path <- liftChecked (relativePath name)
  contents <- ExceptT (Dhall.encodeValue shape value)
  pure (path, Text.encodeUtf8 contents)

materialize :: Dhall.DhallHandling :> es => RootContract -> FileTree -> Value.KnowledgeBase CheckedValue -> Result es Root
materialize selected code (Value.KnowledgeBase (CheckedValue identity value) recipes) = do
  _ <- ExceptT (pure (checkRecipes recipes))
  let contract = rootSchema selected
  ensure (identity == contractId contract) "Checked value belongs to a different contract"
  ensure (all (not . isRootMaterial . fst) (files code))
    "Code snapshot overlaps root data"
  fields <- rootFields contract
  values <- record value
  ensure (sort (map fst fields) == sort (map (Key.toString) (Keys.keys values))) "Root fields do not match contract"
  let collections = collectionContracts contract
      collectionFields = [f | CollectionContract _ f _ _ <- collections]
      residualFields = [(n,s) | (n,s) <- fields, n `notElem` collectionFields]
      residual = object [Key.fromString n .= v | (n,_) <- residualFields, Just v <- [Keys.lookup (Key.fromString n) values]]
  rootFile <- encodeFile (relativeName factsLocation ++ "/root.dhall") (Record residualFields) residual
  entries <- fmap concat $ forM collections $ \(CollectionContract name rootField _ payload) -> do
    members <- field rootField values >>= list
    identities <- forM members $ \member -> record member >>= field "id" >>= text
    ensure (length identities == length (nub identities)) (name ++ ": duplicate fact IDs")
    index <- encodeFile (indexName name) (List (Scalar TextScalar)) (toJSON identities)
    facts <- forM (zip identities members) $ \(factId,member) -> encodeFile (factName name factId) (factShape payload) member
    pure (index : facts)
  snapshot <- liftChecked (fileTree (rootFile : entries))
  pure (Root selected snapshot code emptyCurationRegister recipes)

decodeFile :: Dhall.DhallHandling :> es => FileTree -> String -> Shape -> Result es Value
decodeFile tree name shape = do
  path <- liftChecked (relativePath name)
  contents <- maybe (problem ("Missing file: " ++ name)) pure (lookup path (files tree))
  source <- liftChecked (either (Left . show) Right (Text.decodeUtf8' contents))
  ExceptT (Dhall.decodeValue shape source)

loadValue :: Dhall.DhallHandling :> es => Root -> Result es CheckedValue
loadValue (Root selected snapshot _ _ _) = do
  let contract = rootSchema selected
  fields <- rootFields contract
  let collections = collectionContracts contract
      collectionFields = [f | CollectionContract _ f _ _ <- collections]
      residualFields = [(n,s) | (n,s) <- fields, n `notElem` collectionFields]
  residual <- decodeFile snapshot (relativeName factsLocation ++ "/root.dhall") (Record residualFields) >>= record
  loaded <- forM collections $ \(CollectionContract name rootField _ payload) -> do
    identities <- decodeFile snapshot (indexName name) (List (Scalar TextScalar)) >>= list >>= traverse text
    ensure (length identities == length (nub identities)) (name ++ ": duplicate membership IDs")
    members <- forM identities $ \identity -> do
      member <- decodeFile snapshot (factName name identity) (factShape payload)
      storedId <- record member >>= field "id" >>= text
      ensure (storedId == identity) (name ++ ": fact path/envelope identity mismatch")
      pure member
    pure (rootField, toJSON members, indexName name : map (factName name) identities)
  let expected = (relativeName factsLocation ++ "/root.dhall") : concat [paths | (_,_,paths) <- loaded]
  ensure (sort expected == sort [relativeName path | (path,_) <- files snapshot]) "Unlisted fact files in snapshot"
  let values = foldr (\(name,value,_) -> Keys.insert (Key.fromString name) value) residual loaded
  pure (CheckedValue (contractId contract) (Object values))

exampleShape :: Shape
exampleShape = Record ([(name, Scalar TextScalar) | name <-
  ["name", "query", "inputContract", "resultContract", "explanation"]] ++
  [("requirement", Union [("Required",Nothing),("Illustrative",Nothing)])])

exampleDirectory :: String -> String
exampleDirectory name = "examples/" ++ encoded (Text.pack name) ++ "/"

saveExample :: Dhall.DhallHandling :> es => Example -> Result es FileTree
saveExample (Example name (QueryDescriptor queryName _ input result) (CheckedValue argId arguments)
    (CheckedValue resultId expected) requirement explanation) = do
  ensure (not (null name)) "Example name must not be empty"
  ensure (argId == contractId input && resultId == contractId result) "Example values belong to different query contracts"
  let prefix = exampleDirectory name
      metadata = object ["name" .= name, "query" .= queryName,
        "inputContract" .= contractFingerprint argId, "resultContract" .= contractFingerprint resultId,
        "explanation" .= explanation, "requirement" .= object ["tag" .= show requirement]]
  manifest <- encodeFile (prefix ++ "example.dhall") exampleShape metadata
  args <- encodeFile (prefix ++ "arguments.dhall") (contractShape input) arguments
  expectedFile <- encodeFile (prefix ++ "expected.dhall") (contractShape result) expected
  liftChecked (fileTree [manifest,args,expectedFile])

loadExamples :: Dhall.DhallHandling :> es => FileTree -> [QueryDescriptor] -> Result es [Example]
loadExamples code descriptors = do
  let paths = [relativeName path | (path,_) <- files code,
        relativeName path == "examples" || "examples/" `isPrefixOf` relativeName path]
      directories = nub [takeWhile (/= '/') suffix | path <- paths, Just suffix <- [stripPrefix "examples/" path]]
      expectedPaths = ["examples/" ++ directory ++ "/" ++ file | directory <- directories,
        file <- ["example.dhall","arguments.dhall","expected.dhall"]]
  ensure (sort paths == sort expectedPaths) "Each example must contain exactly example.dhall, arguments.dhall and expected.dhall"
  forM directories $ \directory -> do
    let prefix = "examples/" ++ directory ++ "/"
    values <- decodeFile code (prefix ++ "example.dhall") exampleShape >>= record
    name <- Text.unpack <$> (field "name" values >>= text)
    let withLocation action = ExceptT $ do
          outcome <- runExceptT action
          pure (either (Left . map (\(Diagnostic level diagnosticCode message _) ->
            Diagnostic level diagnosticCode message (Just (ExampleLocation name)))) Right outcome)
    withLocation $ do
      ensure (not (null name) && prefix == exampleDirectory name) "Example name does not match its directory"
      queryName <- Text.unpack <$> (field "query" values >>= text)
      descriptor@(QueryDescriptor _ _ input result) <- case
        [d | d@(QueryDescriptor n _ _ _) <- descriptors, n == queryName] of
          [d] -> pure d
          _ -> problem ("Unknown query " ++ queryName ++ "; update the example")
      inputId <- field "inputContract" values >>= text
      resultId <- field "resultContract" values >>= text
      ensure (inputId == Text.pack (contractFingerprint (contractId input)) &&
        resultId == Text.pack (contractFingerprint (contractId result)))
        (queryName ++ ": contracts changed; rebuild the example against the current query")
      requirementTag <- field "requirement" values >>= record >>= field "tag" >>= text
      requirement <- case requirementTag of
        "Required" -> pure Required
        "Illustrative" -> pure Illustrative
        _ -> problem "Unknown example requirement"
      explanation <- Text.unpack <$> (field "explanation" values >>= text)
      arguments <- decodeFile code (prefix ++ "arguments.dhall") (contractShape input)
      expected <- decodeFile code (prefix ++ "expected.dhall") (contractShape result)
      pure (Example name descriptor (CheckedValue (contractId input) arguments)
        (CheckedValue (contractId result) expected) requirement explanation)
