module Kyyn.Domain.Contract
  ( CheckedContract, ContractId, CollectionContract(..), checkContract
  , rootType, metadataOf, contractShape, contractId, contractFingerprint, parseContractFingerprint, collectionContracts
  , RootContract, checkRootLayout, rootSchema, describeRootContract ) where

import Control.Monad (unless, forM_)
import Data.Coerce (coerce)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.Aeson (Value, toJSON, encode)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.List (nub)
import qualified Data.Text as Text
import Numeric (showHex, readHex)
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Types.SchemaMetadata

newtype ContractId = ContractId Bytes.ByteString deriving (Eq, Show)

parseContractFingerprint :: String -> Either String ContractId
parseContractFingerprint value
  | length value == 64 && all (`elem` ("0123456789abcdef" :: String)) value =
      ContractId . Bytes.pack <$> pairs value
  | otherwise = Left "Expected a 64-character lowercase hexadecimal contract fingerprint"
  where
    pairs [] = Right []
    pairs (a:b:rest) = case readHex [a,b] of
      [(byte,"")] -> (byte:) <$> pairs rest
      _ -> Left "Invalid contract fingerprint"
    pairs _ = Left "Invalid contract fingerprint"
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
      roleNames = [Text.unpack n | RoleDecl n _ _ <- roles]
      collectionNames = [Text.unpack n | CollectionDecl n _ _ <- declarations]
      rootNames = [Text.unpack f | CollectionDecl _ f _ <- declarations]
  unique "role names" roleNames
  unique "collection names" collectionNames
  unique "collection root fields" rootNames
  forM_ (roleNames ++ collectionNames) $ \name ->
    unless (not (null name)) (Left "role and collection names must not be empty")
  assigned <- mapM (checkRole root roles) assignments
  unique "role assignments per record" [(record,role) | FieldRole record _ role <- assignments]
  unique "singular affordance assignments per record" [(record,affordance) | (record,affordance) <- assigned, affordance /= Badge]
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
recordFields (Algebraic _ _ cs@[Constructor _ fs])
  | isRecord cs =
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
checkRole root roles (FieldRole recordText fieldText roleText) = do
  let record = Text.unpack recordText; field = Text.unpack fieldText; role = Text.unpack roleText
  affordance <- case [a | RoleDecl n _ a <- roles, n == roleText] of
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
compatible Title TextType = True
compatible Badge (Algebraic _ _ cs) = not (null cs) && all (\(Constructor _ fs) -> null fs) cs
compatible _ _ = False

factPayload :: DataType -> Maybe DataType
factPayload (ListType t) = sdkFactPayload t
factPayload _ = Nothing

checkCollection :: [(String, DataType)] -> [String] -> CollectionDecl -> Either String CollectionContract
checkCollection fields names (CollectionDecl nameText fieldText refs) = do
  let name = Text.unpack nameText; field = Text.unpack fieldText
      references = [(Text.unpack f,Text.unpack c) | (f,c) <- refs]
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
typeValue TextType = toJSON ["packed-text" :: String]
typeValue IntegerType = toJSON ["integer" :: String]
typeValue ProbabilityType = toJSON ["probability-basis-points" :: String]
typeValue BoolType = toJSON ["bool" :: String]
typeValue UnitType = toJSON ["unit" :: String]
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
