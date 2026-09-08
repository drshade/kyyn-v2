{-# LANGUAGE DeriveAnyClass #-}
module Kyyn.Domain.DataType
  ( DataType(..), Constructor(..), Shape(..), ScalarKind(..), shapeOf
  , haskellType, reachableTypes, definingModule, sdkFactIdType, sdkFactPayload ) where

import Data.List (nub)
import Control.DeepSeq (NFData)
import GHC.Generics (Generic)

-- Resolved data declarations only; a complete KB contract also needs metadata.
data DataType
  = StringType | IntegerType | BoolType
  | ListType DataType | OptionalType DataType
  | Algebraic String [DataType] [Constructor]
  deriving (Eq, Show, Generic, NFData)

data Constructor = Constructor String [(Maybe String, DataType)]
  deriving (Eq, Show, Generic, NFData)

data Shape
  = Record [(String, Shape)] | List Shape | Optional Shape
  | Union [(String, Maybe Shape)] | Scalar ScalarKind | Reference String
  deriving (Eq, Show)

data ScalarKind = TextScalar | IntegerScalar | BoolScalar deriving (Eq, Show)

-- Constructor/module information binds this structural projection to authored code.
shapeOf :: DataType -> Either String Shape
shapeOf StringType = Right (Scalar TextScalar)
shapeOf IntegerType = Right (Scalar IntegerScalar)
shapeOf BoolType = Right (Scalar BoolScalar)
shapeOf (ListType t) = List <$> shapeOf t
shapeOf (OptionalType t) = Optional <$> shapeOf t
shapeOf t@(Algebraic "Kyyn.Types.Fact.FactId" _ _)
  | t == sdkFactIdType = Right (Scalar TextScalar)
  | otherwise = Left "unsupported SDK FactId representation"
shapeOf t@(Algebraic "Kyyn.Types.Fact.Fact" _ _) = case sdkFactPayload t of
  Just p -> Record <$> sequence [(,) "id" <$> shapeOf sdkFactIdType, (,) "value" <$> shapeOf p]
  Nothing -> Left "unsupported SDK Fact representation"
shapeOf (Algebraic _ _ [Constructor _ fs])
  | not (null fs) && all named fs = Record <$> recordFields fs
shapeOf (Algebraic _ _ cs) = Union <$> mapM arm cs
  where
    arm (Constructor name fs) = (,) (reverse (takeWhile (/= '.') (reverse name))) <$> payload name fs
    payload _ [] = Right Nothing
    payload _ fs | all named fs = Just . Record <$> recordFields fs
    payload _ [(_,t)] = Just <$> shapeOf t
    payload name _ = Left (name ++ ": multiple positional fields are not supported; use a record payload")

named :: (Maybe String, a) -> Bool
named (name, _) = name /= Nothing

sdkFactIdType :: DataType
sdkFactIdType = Algebraic "Kyyn.Types.Fact.FactId" []
  [Constructor "Kyyn.Types.Fact.FactId" [(Nothing, StringType)]]

sdkFactPayload :: DataType -> Maybe DataType
sdkFactPayload (Algebraic "Kyyn.Types.Fact.Fact" [p]
  [Constructor "Kyyn.Types.Fact.Fact" [(Nothing, i), (Nothing, v)]])
  | i == sdkFactIdType && p == v = Just p
sdkFactPayload _ = Nothing

recordFields :: [(Maybe String, DataType)] -> Either String [(String, Shape)]
recordFields fs = mapM (\(name,t) -> (,) name <$> shapeOf t) [(name,t) | (Just name,t) <- fs]

haskellType :: DataType -> String
haskellType StringType = "String"
haskellType IntegerType = "Integer"
haskellType BoolType = "Bool"
haskellType (ListType t) = "[" ++ haskellType t ++ "]"
haskellType (OptionalType t) = "(Maybe " ++ haskellType t ++ ")"
haskellType (Algebraic name args _) = "(" ++ unwords (name : map haskellType args) ++ ")"

reachableTypes :: DataType -> [DataType]
reachableTypes t = nub (t : case t of
  ListType a -> reachableTypes a
  OptionalType a -> reachableTypes a
  Algebraic _ args cs -> concatMap reachableTypes
    (args ++ [a | Constructor _ fields <- cs, (_,a) <- fields])
  _ -> [])

definingModule :: String -> String
definingModule = reverse . drop 1 . dropWhile (/= '.') . reverse
