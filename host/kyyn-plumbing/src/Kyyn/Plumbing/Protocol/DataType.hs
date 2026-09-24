module Kyyn.Plumbing.Protocol.DataType (dataTypeShape, dataTypeValue, parseDataType) where

import Control.Monad (foldM)
import Data.Aeson (Value, object, (.=), toJSON, withObject, (.:))
import Data.Aeson.Types (Parser, parseJSON)
import Data.List (nub, elemIndex)
import Kyyn.Domain.DataType

dataTypeShape :: Shape
dataTypeShape = List (Union [("Text",Nothing), ("Integer",Nothing), ("Bool",Nothing),
  ("List",Just index), ("Optional",Just index),
  ("Data",Just (Record [("name",text),("arguments",List index),
    ("constructors",List (Record [("name",text),("fields",List
      (Record [("name",Optional text),("type",index)]))]))]))])
  where text = Scalar TextScalar; index = Scalar IntegerScalar

dataTypeValue :: DataType -> Value
dataTypeValue root = toJSON (map node types)
  where
    types = nub (ordered root)
    reference t = maybe (error "Type encoding omitted a dependency") (toJSON . show) (elemIndex t types)
    node StringType = tagged "Text" Nothing
    node IntegerType = tagged "Integer" Nothing
    node BoolType = tagged "Bool" Nothing
    node (ListType item) = tagged "List" (Just (reference item))
    node (OptionalType item) = tagged "Optional" (Just (reference item))
    node (Algebraic name arguments constructors) = tagged "Data" (Just (object
      ["name" .= name, "arguments" .= map reference arguments,
       "constructors" .= [object ["name" .= n, "fields" .=
         [object ["name" .= maybe (tagged "None" Nothing) (tagged "Some" . Just . toJSON) label,
                  "type" .= reference t] | (label,t) <- fields]] | Constructor n fields <- constructors]]))

parseDataType :: Value -> Parser DataType
parseDataType input = do
  nodes <- parseJSON input :: Parser [Value]
  types <- foldM (\previous item -> do next <- node previous item; pure (previous ++ [next])) [] nodes
  case reverse types of
    root : _ -> pure root
    [] -> fail "No root type"
  where
    reference previous value = do
      source <- parseJSON value
      case reads source of
        [(i,"")] | i >= (0 :: Integer), i < toInteger (length previous), show i == source -> pure (previous !! fromInteger i)
        _ -> fail "Type reference must identify an earlier declaration"
    node previous = withObject "Type declaration" $ \record -> do
      tag <- record .: "tag" :: Parser String
      case tag of
        "Text" -> pure StringType
        "Integer" -> pure IntegerType
        "Bool" -> pure BoolType
        "List" -> ListType <$> (record .: "value" >>= reference previous)
        "Optional" -> OptionalType <$> (record .: "value" >>= reference previous)
        "Data" -> record .: "value" >>= withObject "Data declaration" (\decl ->
          Algebraic <$> decl .: "name" <*> (decl .: "arguments" >>= traverse (reference previous))
            <*> (decl .: "constructors" >>= traverse (constructor previous)))
        _ -> fail "Unknown type declaration"
    constructor previous = withObject "Constructor" $ \record -> Constructor
      <$> record .: "name" <*> (record .: "fields" >>= traverse (withObject "Field" (\field ->
        (,) <$> (field .: "name" >>= withObject "Optional name" (\name -> do
          tag <- name .: "tag" :: Parser String
          case tag of "None" -> pure Nothing; "Some" -> Just <$> name .: "value"; _ -> fail "Expected Some or None"))
          <*> (field .: "type" >>= reference previous))))

ordered :: DataType -> [DataType]
ordered t = (case t of
  ListType item -> ordered item
  OptionalType item -> ordered item
  Algebraic _ arguments constructors -> concatMap ordered (arguments ++ [field | Constructor _ fields <- constructors, (_,field) <- fields])
  _ -> []) ++ [t]

tagged :: String -> Maybe Value -> Value
tagged tag value = object (["tag" .= tag] ++ maybe [] (\v -> ["value" .= v]) value)
