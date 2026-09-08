module Kyyn.Domain.Contract
  ( CheckedContract, ContractId, CollectionContract(..), checkContract
  , rootType, metadataOf, contractShape, contractId, contractFingerprint, collectionContracts
  , RootContract, checkRootLayout, rootSchema, describeRootContract, restoreRootContract ) where

import Control.Monad (unless, forM_)
import Data.Coerce (coerce)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.Aeson (Value, toJSON, encode)
import Data.Aeson.Types (Parser, parseEither, parseJSON)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.List (nub)
import Numeric (showHex)
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Types.SchemaMetadata

newtype ContractId = ContractId Bytes.ByteString deriving (Eq, Show)
data CollectionContract = CollectionContract
  { collectionName :: String, rootFieldName :: String
  , payloadType :: DataType, payloadShape :: Shape
  } deriving (Eq, Show)
data CheckedContract = CheckedContract DataType SchemaMetadata Shape [CollectionContract] ContractId
  deriving (Eq, Show)
newtype RootContract = RootContract CheckedContract deriving (Eq, Show)

rootSchema :: RootContract -> CheckedContract
rootSchema = coerce

rootType :: CheckedContract -> DataType
rootType (CheckedContract t _ _ _ _) = t
metadataOf :: CheckedContract -> SchemaMetadata
metadataOf (CheckedContract _ m _ _ _) = m
contractShape :: CheckedContract -> Shape
contractShape (CheckedContract _ _ s _ _) = s
collectionContracts :: CheckedContract -> [CollectionContract]
collectionContracts (CheckedContract _ _ _ cs _) = cs
contractId :: CheckedContract -> ContractId
contractId (CheckedContract _ _ _ _ i) = i

contractFingerprint :: ContractId -> String
contractFingerprint (ContractId bytes) = concatMap hex (Bytes.unpack bytes)
  where
    hex byte = let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits

checkContract :: DataType -> SchemaMetadata -> Either [Diagnostic] CheckedContract
checkContract root meta = either (Left . pure . errorDiagnostic "schema.incoherent") Right $ do
  validateStructure root
  let rootFields = either (const []) id (recordFields root)
  let SchemaMetadata roles assignments declarations = meta
      roleNames = [n | RoleDecl n _ _ <- roles]
      collectionNames = [n | CollectionDecl n _ _ <- declarations]
      rootNames = [f | CollectionDecl _ f _ <- declarations]
  unique "role names" roleNames
  unique "collection names" collectionNames
  unique "collection root fields" rootNames
  forM_ (roleNames ++ collectionNames) $ \name ->
    unless (not (null name)) (Left "role and collection names must not be empty")
  assigned <- mapM (checkRole root roles) assignments
  unique "affordance assignments per record" assigned
  collections <- mapM (checkCollection rootFields collectionNames) declarations
  originalShape <- shapeOf root
  collectionShapes <- mapM (\c@(CollectionContract _ f _ _) -> (,) f <$> collectionShape c) collections
  let shape = case originalShape of
        Record fields -> Record [(n, maybe s id (lookup n collectionShapes)) | (n,s) <- fields]
        other -> other
      identity = ContractId (SHA256.hash (Lazy.toStrict (encode
        ("kyyn-contract-1" :: String, typeValue root, metadataValue meta))))
  pure (CheckedContract root meta shape collections identity)

checkRootLayout :: CheckedContract -> Either [Diagnostic] RootContract
checkRootLayout contract = either (Left . pure . errorDiagnostic "schema.incoherent") Right $ do
  fields <- recordFields (rootType contract)
  let declared = [field | CollectionContract _ field _ _ <- collectionContracts contract]
  forM_ fields $ \(name,t) -> case factPayload t of
    Just _ -> unless (name `elem` declared) (Left (name ++ ": missing collection declaration"))
    Nothing -> pure ()
  pure (RootContract contract)

unique :: (Eq a, Show a) => String -> [a] -> Either String ()
unique label xs = unless (length (nub xs) == length xs) (Left ("duplicate " ++ label ++ ": " ++ show xs))

recordFields :: DataType -> Either String [(String, DataType)]
recordFields (Algebraic _ _ [Constructor _ fs])
  | not (null fs) && all (\(name,_) -> name /= Nothing) fs =
      Right [(n,t) | (Just n,t) <- fs]
recordFields t = Left (haskellType t ++ ": expected a single record constructor")

validateStructure :: DataType -> Either String ()
validateStructure root = do
  _ <- shapeOf root
  forM_ (reachableTypes root) $ \t -> case t of
    Algebraic name _ cs -> do
      unless (not (null cs)) (Left (name ++ ": empty constructor set"))
      unique (name ++ " constructor tags") [shortName n | Constructor n _ <- cs]
      forM_ cs $ \(Constructor n fs) -> do
        unique (n ++ " fields") [f | (Just f,_) <- fs]
        unless (all (not . null) [f | (Just f,_) <- fs]) (Left (n ++ ": empty field name"))
    _ -> pure ()

checkRole :: DataType -> [RoleDecl] -> FieldRole -> Either String (String, Affordance)
checkRole root roles (FieldRole record field role) = do
  affordance <- case [a | RoleDecl n _ a <- roles, n == role] of
    [a] -> Right a
    _ -> Left (role ++ ": unknown role")
  selected <- case [t | t@(Algebraic name _ _) <- reachableTypes root, name == record] of
    [t] -> Right t
    [] -> Left (record ++ ": unknown record type")
    _ -> Left (record ++ ": ambiguous applied record type")
  fields <- recordFields selected
  t <- maybe (Left (record ++ "." ++ field ++ ": missing field")) Right (lookup field fields)
  unless (compatible affordance t) (Left (record ++ "." ++ field ++ ": incompatible " ++ show affordance ++ " role"))
  pure (record, affordance)

compatible :: Affordance -> DataType -> Bool
compatible a (OptionalType t) = compatible a t
compatible Title StringType = True
compatible Badge (Algebraic _ _ cs) = not (null cs) && all (\(Constructor _ fs) -> null fs) cs
compatible _ _ = False

factPayload :: DataType -> Maybe DataType
factPayload (ListType t) = sdkFactPayload t
factPayload _ = Nothing

checkCollection :: [(String, DataType)] -> [String] -> CollectionDecl -> Either String CollectionContract
checkCollection fields names (CollectionDecl name field references) = do
  t <- maybe (Left (field ++ ": missing root field")) Right (lookup field fields)
  payload <- maybe (Left (field ++ ": expected [Kyyn.Types.Fact.Fact payload]")) Right (factPayload t)
  unique (name ++ " reference fields") (map fst references)
  shape <- shapeOf payload
  annotated <- if null references then pure shape else do
    fs <- recordFields payload
    forM_ references $ \(f,target) -> do
      unless (target `elem` names) (Left (name ++ "." ++ f ++ ": unknown target collection " ++ target))
      ft <- maybe (Left (name ++ "." ++ f ++ ": missing reference field")) Right (lookup f fs)
      unless (referenceType ft) (Left (name ++ "." ++ f ++ ": expected FactId, optionally or in a list"))
    Record <$> mapM (\(f,ft) -> do
      s <- shapeOf ft
      pure (f, maybe s (referenceShape ft) (lookup f references))) fs
  pure (CollectionContract name field payload annotated)

referenceType :: DataType -> Bool
referenceType t | t == sdkFactIdType = True
referenceType (OptionalType t) = referenceType t
referenceType (ListType t) = referenceType t
referenceType _ = False

referenceShape :: DataType -> String -> Shape
referenceShape (OptionalType t) target = Optional (referenceShape t target)
referenceShape (ListType t) target = List (referenceShape t target)
referenceShape _ target = Reference target

collectionShape :: CollectionContract -> Either String Shape
collectionShape (CollectionContract _ _ _ payload) = do
  identity <- shapeOf sdkFactIdType
  pure (List (Record [("id", identity), ("value", payload)]))

shortName :: String -> String
shortName = reverse . takeWhile (/= '.') . reverse

typeValue :: DataType -> Value
typeValue StringType = toJSON ["text" :: String]
typeValue IntegerType = toJSON ["integer" :: String]
typeValue BoolType = toJSON ["bool" :: String]
typeValue (ListType t) = toJSON ("list" :: String, typeValue t)
typeValue (OptionalType t) = toJSON ("optional" :: String, typeValue t)
typeValue (Algebraic name args cs) = toJSON ("data" :: String, name, map typeValue args,
  [(n, [(f,typeValue t) | (f,t) <- fs]) | Constructor n fs <- cs])

metadataValue :: SchemaMetadata -> Value
metadataValue (SchemaMetadata roles fields collections) = toJSON
  ([(n,d,tag a) | RoleDecl n d a <- roles],
   [(t,f,r) | FieldRole t f r <- fields],
   [(n,f,rs) | CollectionDecl n f rs <- collections])
  where
    tag Title = "title" :: String
    tag Timeline = "timeline"
    tag Badge = "badge"

describeRootContract :: RootContract -> Value
describeRootContract root = let contract = rootSchema root in toJSON
  (1 :: Int, contractFingerprint (contractId contract), typeValue (rootType contract), metadataValue (metadataOf contract))

restoreRootContract :: Value -> Either String (Either [Diagnostic] RootContract)
restoreRootContract = parseEither $ \value -> do
  (version, fingerprint, structure, metadata) <- parseJSON value
  if version /= (1 :: Int) then pure stale else do
    t <- parseType structure
    m <- parseMetadata metadata
    pure $ case checkContract t m >>= checkRootLayout of
      Right contract | contractFingerprint (contractId (rootSchema contract)) == fingerprint -> Right contract
      _ -> stale
  where
    stale = Left [errorDiagnostic "schema.stored-contract" "Stored contract cannot be reconstructed with its fingerprint by this kernel"]

parseType :: Value -> Parser DataType
parseType value = do
  parts <- parseJSON value
  case parts of
    [tagValue] -> do
      tag <- parseJSON tagValue
      case tag :: String of
        "text" -> pure StringType
        "integer" -> pure IntegerType
        "bool" -> pure BoolType
        _ -> fail "Unknown scalar contract type"
    [tagValue, item] -> do
      tag <- parseJSON tagValue
      case tag :: String of
        "list" -> ListType <$> parseType item
        "optional" -> OptionalType <$> parseType item
        _ -> fail "Unknown container contract type"
    [tagValue, name, args, constructors] -> do
      tag <- parseJSON tagValue
      unless (tag == ("data" :: String)) (fail "Expected data contract type")
      Algebraic <$> parseJSON name <*> (parseJSON args >>= traverse parseType)
        <*> (parseJSON constructors >>= traverse parseConstructor)
    _ -> fail "Invalid contract type description"
  where
    parseConstructor v = do
      (name, fields) <- parseJSON v
      Constructor name <$> traverse (\(field,t) -> (,) field <$> parseType t) fields

parseMetadata :: Value -> Parser SchemaMetadata
parseMetadata value = do
  (roles, fields, collections) <- parseJSON value
  SchemaMetadata <$> traverse role roles
    <*> pure [FieldRole t f r | (t,f,r) <- fields]
    <*> pure [CollectionDecl n f rs | (n,f,rs) <- collections]
  where
    role (name, description, tag) = RoleDecl name description <$> case tag :: String of
      "title" -> pure Title
      "timeline" -> pure Timeline
      "badge" -> pure Badge
      _ -> fail "Unknown role affordance"
