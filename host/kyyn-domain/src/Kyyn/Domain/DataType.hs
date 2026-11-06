{-# LANGUAGE DeriveAnyClass #-}
module Kyyn.Domain.DataType
  ( DataType(..), Constructor(..), Shape(..), ScalarKind(..), shapeOf, isRecord
  , haskellType, reachableTypes, typeModules, definingModule, sdkFactIdType, sdkFactPayload, descriptionType ) where

import Data.List (nub)
import qualified Data.Text as Text
import qualified Kyyn.Types.Contract as D
import Control.DeepSeq (NFData)
import GHC.Generics (Generic)

data Shape
  = Record [(String, Shape)] | List Shape | Optional Shape
  | Union [(String, Maybe Shape)] | Scalar ScalarKind | Reference String
  deriving (Eq, Show)

data ScalarKind = TextScalar | IntegerScalar | NaturalScalar | BoolScalar | ProbabilityScalar
  | ExactScalar D.ScalarKind deriving (Eq, Show)


-- Resolved data declarations only; a complete KB contract also needs metadata.
data DataType
  = StringType | TextType | IntegerType | BoolType | ProbabilityType | UnitType
  | ScalarType D.TypeIdentity D.ScalarKind
  | ListType DataType | OptionalType DataType
  | Algebraic String [DataType] [Constructor]
  deriving (Eq, Show, Generic, NFData)

data Constructor = Constructor String [(Maybe String, DataType)]
  deriving (Eq, Show, Generic, NFData)

-- Constructor/module information binds this structural projection to authored code.
shapeOf :: DataType -> Either String Shape
shapeOf StringType = Right (Scalar TextScalar)
shapeOf TextType = Right (Scalar TextScalar)
shapeOf IntegerType = Right (Scalar IntegerScalar)
shapeOf BoolType = Right (Scalar BoolScalar)
shapeOf ProbabilityType = Right (Scalar ProbabilityScalar)
shapeOf (ScalarType _ kind) = Right (Scalar (ExactScalar kind))
shapeOf UnitType = Right (Record [])
shapeOf (ListType t) = List <$> shapeOf t
shapeOf (OptionalType t) = Optional <$> shapeOf t
shapeOf t@(Algebraic "Kyyn.Types.Fact.FactId" _ _)
  | t == sdkFactIdType = Right (Scalar (ExactScalar D.FactIdScalar))
  | otherwise = Left "unsupported SDK FactId representation"
shapeOf t@(Algebraic "Kyyn.Types.Fact.Fact" _ _) = case sdkFactPayload t of
  Just p -> Record <$> sequence [(,) "id" <$> shapeOf sdkFactIdType, (,) "value" <$> shapeOf p]
  Nothing -> Left "unsupported SDK Fact representation"
shapeOf (Algebraic _ _ cs@[Constructor _ fs])
  | isRecord cs = Record <$> recordFields fs
shapeOf (Algebraic _ _ cs) = Union <$> mapM arm cs
  where
    arm (Constructor name fs) = (,) (reverse (takeWhile (/= '.') (reverse name))) <$> payload name fs
    payload _ [] = Right Nothing
    payload _ fs | all named fs = Just . Record <$> recordFields fs
    payload _ [(_,t)] = Just <$> shapeOf t
    payload name _ = Left (name ++ ": multiple positional fields are not supported; use a record payload")

named :: (Maybe String, a) -> Bool
named (name, _) = name /= Nothing

isRecord :: [Constructor] -> Bool
isRecord [Constructor _ fs] = all named fs
isRecord _ = False

sdkFactIdType :: DataType
sdkFactIdType = Algebraic "Kyyn.Types.Fact.FactId" []
  [Constructor "Kyyn.Types.Fact.FactId" [(Nothing, TextType)]]

sdkFactPayload :: DataType -> Maybe DataType
sdkFactPayload (Algebraic "Kyyn.Types.Fact.Fact" [p]
  [Constructor "Kyyn.Types.Fact.Fact" [(Nothing, i), (Nothing, v)]])
  | i == sdkFactIdType && p == v = Just p
sdkFactPayload (Algebraic "Kyyn.Types.Fact.Fact" [_]
  [Constructor _ [(Just "id", i), (Just "value", v)]])
  | i == sdkFactIdType = Just v
sdkFactPayload _ = Nothing

recordFields :: [(Maybe String, DataType)] -> Either String [(String, Shape)]
recordFields fs = mapM (\(name,t) -> (,) name <$> shapeOf t) [(name,t) | (Just name,t) <- fs]

haskellType :: DataType -> String
haskellType (ScalarType identity _) = resolvedName identity
haskellType StringType = "String"
haskellType TextType = "Data.Text.Text"
haskellType IntegerType = "Integer"
haskellType BoolType = "Bool"
haskellType ProbabilityType = "Agentic.Questions.Probability"
haskellType UnitType = "()"
haskellType (ListType t) = "[" ++ haskellType t ++ "]"
haskellType (OptionalType t) = "(Maybe " ++ haskellType t ++ ")"
haskellType (Algebraic name [] _) = name
haskellType (Algebraic name args _) = "(" ++ unwords (name : map haskellType args) ++ ")"

reachableTypes :: DataType -> [DataType]
reachableTypes t = nub (t : case t of
  ListType a -> reachableTypes a
  OptionalType a -> reachableTypes a
  Algebraic _ _ cs -> concatMap reachableTypes
    [a | Constructor _ fields <- cs, (_,a) <- fields]
  _ -> [])

definingModule :: String -> String
definingModule = reverse . drop 1 . dropWhile (/= '.') . reverse

typeModules :: DataType -> [String]
typeModules = nub . concatMap selected . reachableTypes
  where
    selected (Algebraic name _ _) = [definingModule name]
    selected (ScalarType identity _) = [definingModule (resolvedName identity)]
    selected ProbabilityType = ["Agentic.Questions"]
    selected TextType = ["Data.Text"]
    selected _ = []

-- The descriptor retains identity and annotations; this is only the host's
-- declaration projection for field selection and Haskell binding generation.
descriptionType :: D.Description -> DataType
descriptionType description = case description of
  D.ScalarDescription identity kind _ _ -> case kind of
    D.TextScalar -> TextType
    D.BoolScalar -> BoolType
    D.IntegerScalar -> IntegerType
    D.ProbabilityScalar -> ProbabilityType
    D.FactIdScalar -> sdkFactIdType
    _ -> ScalarType identity kind
  D.NamedDescription identity inner -> case descriptionType inner of
    Algebraic _ _ constructors -> Algebraic (Text.unpack (D.qualifiedTypeName identity))
      (typeArguments identity) (map (qualify identity) constructors)
    value -> value
  D.RecordDescription name style fields -> Algebraic "" [] [constructor name style fields]
  D.SumDescription cases -> Algebraic "" []
    [constructor name style fields | D.CaseDescription name _ style fields <- cases]
  D.ListDescription inner -> ListType (descriptionType inner)
  D.OptionalDescription inner -> OptionalType (descriptionType inner)
  D.UnitDescription -> UnitType
  D.CheckedDescription _ inner -> descriptionType inner
  D.DocumentedDescription _ inner -> descriptionType inner
  where
    constructor name style fields = Constructor (Text.unpack name)
      [(if style == D.NamedFields then Just (Text.unpack field) else Nothing, descriptionType inner)
      | D.FieldDescription field _ inner <- fields]
    qualify identity (Constructor name fields) = Constructor
      (definingModule (Text.unpack (D.qualifiedTypeName identity)) ++ "." ++ name) fields
    typeArguments (D.TypeIdentity _ _ _ args) = map typeArgument args
    typeArgument identity@(D.TypeIdentity _ _ _ args) =
      Algebraic (Text.unpack (D.qualifiedTypeName identity)) (map typeArgument args) []

resolvedName :: D.TypeIdentity -> String
resolvedName identity@(D.TypeIdentity _ _ _ args)
  | null args = Text.unpack (D.qualifiedTypeName identity)
  | otherwise = "(" ++ unwords (Text.unpack (D.qualifiedTypeName identity) : map resolvedName args) ++ ")"
