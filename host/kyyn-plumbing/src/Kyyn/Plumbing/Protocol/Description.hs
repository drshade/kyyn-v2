{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Plumbing.Protocol.Description (descriptionShape, descriptionValue, parseDescription) where

import Control.Monad (foldM)
import Data.Aeson (Value, object, (.=), toJSON, withObject, (.:))
import Data.Aeson.Types (Parser, parseJSON)
import Data.List (nub, elemIndex)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Kyyn.Types.Contract as D
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))

-- Dhall has no recursive data types. Store finite descriptions in dependency
-- order and require every reference to point to an earlier node.
descriptionShape :: Shape
descriptionShape = Record
  [("types",List (Record [("package",text),("module",text),("name",text),("arguments",List index)])),
   ("nodes",List (Union
     [("Scalar",Just (Record [("type",index),("kind",List text),("name",text),("parameters",List pair)])),
      ("Named",Just (Record [("type",index),("inner",index)])),
      ("Record",Just (Record [("name",text),("style",style),("fields",List field)])),
      ("Sum",Just (List (Record [("name",text),("doc",text),("style",style),("fields",List field)]))),
      ("List",Just index),("Optional",Just index),("Unit",Nothing),
      ("Checked",Just annotation),("Documented",Just annotation)]))]
  where
    text = Scalar TextScalar
    index = Scalar IntegerScalar
    style = Union [("Named",Nothing),("Positional",Nothing)]
    pair = Record [("name",text),("value",text)]
    field = Record [("name",text),("doc",text),("inner",index)]
    annotation = Record [("text",text),("inner",index)]

descriptionValue :: D.Description -> Value
descriptionValue root = object ["types" .= map typeValue types,"nodes" .= map nodeValue nodes]
  where
    nodes = nub (ordered root)
    types = nub (concatMap identities nodes)
    typeReference = reference types
    nodeReference = reference nodes
    typeValue (D.TypeIdentity packageName moduleName name arguments) = object
      ["package" .= packageName,"module" .= moduleName,"name" .= name,"arguments" .= map typeReference arguments]
    fieldValue (D.FieldDescription name doc inner) = object
      ["name" .= name,"doc" .= doc,"inner" .= nodeReference inner]
    caseValue (D.CaseDescription name doc style fields) = object
      ["name" .= name,"doc" .= doc,"style" .= styleValue style,"fields" .= map fieldValue fields]
    styleValue D.NamedFields = tagged "Named" Nothing
    styleValue D.PositionalFields = tagged "Positional" Nothing
    annotation text inner = object ["text" .= text,"inner" .= nodeReference inner]
    nodeValue description = case description of
      D.ScalarDescription identity kind name parameters -> tagged "Scalar" (Just (object
        ["type" .= typeReference identity,"kind" .= kind,"name" .= name,
         "parameters" .= [object ["name" .= key,"value" .= value] | (key,value) <- parameters]]))
      D.NamedDescription identity inner -> tagged "Named" (Just (object
        ["type" .= typeReference identity,"inner" .= nodeReference inner]))
      D.RecordDescription name style fields -> tagged "Record" (Just (object
        ["name" .= name,"style" .= styleValue style,"fields" .= map fieldValue fields]))
      D.SumDescription cases -> tagged "Sum" (Just (toJSON (map caseValue cases)))
      D.ListDescription inner -> tagged "List" (Just (nodeReference inner))
      D.OptionalDescription inner -> tagged "Optional" (Just (nodeReference inner))
      D.UnitDescription -> tagged "Unit" Nothing
      D.CheckedDescription label inner -> tagged "Checked" (Just (annotation label inner))
      D.DocumentedDescription doc inner -> tagged "Documented" (Just (annotation doc inner))

parseDescription :: Value -> Parser D.Description
parseDescription = withObject "contract description" $ \document -> do
  typeNodes <- document .: "types" :: Parser [Value]
  types <- foldM (\previous node -> do
    next <- withObject "resolved type" (\fields -> D.TypeIdentity
      <$> fields .: "package" <*> fields .: "module" <*> fields .: "name"
      <*> (fields .: "arguments" >>= traverse (resolve previous))) node
    pure (previous ++ [next])) [] typeNodes
  input <- document .: "nodes" :: Parser [Value]
  nodes <- foldM (\previous node -> do
    next <- parseNode types previous node
    pure (previous ++ [next])) [] input
  case reverse nodes of
    root:_ -> either (fail . Text.unpack) (const (pure root)) (D.validateDescription root)
    [] -> fail "No root contract description"
  where
    parseNode types previous = withObject "description node" $ \record -> do
      tag <- record .: "tag" :: Parser Text
      let body action = record .: "value" >>= action
          fieldsOf = traverse (withObject "field" (\field -> D.FieldDescription
            <$> field .: "name" <*> field .: "doc" <*> (field .: "inner" >>= resolve previous)))
          annotation constructor = body $ withObject "annotation" $ \fields ->
            constructor <$> fields .: "text" <*> (fields .: "inner" >>= resolve previous)
      case tag of
        "Scalar" -> body $ withObject "scalar" $ \fields -> D.ScalarDescription
          <$> (fields .: "type" >>= resolve types) <*> fields .: "kind" <*> fields .: "name"
          <*> (fields .: "parameters" >>= traverse (withObject "parameter" (\pair -> (,)
            <$> pair .: "name" <*> pair .: "value")))
        "Named" -> body $ withObject "named type" $ \fields -> D.NamedDescription
          <$> (fields .: "type" >>= resolve types) <*> (fields .: "inner" >>= resolve previous)
        "Record" -> body $ withObject "record" $ \fields -> D.RecordDescription
          <$> fields .: "name" <*> (fields .: "style" >>= parseStyle) <*> (fields .: "fields" >>= fieldsOf)
        "Sum" -> body $ \value -> D.SumDescription <$> (parseJSON value >>= traverse
          (withObject "case" (\fields -> D.CaseDescription
            <$> fields .: "name" <*> fields .: "doc" <*> (fields .: "style" >>= parseStyle)
            <*> (fields .: "fields" >>= fieldsOf))))
        "List" -> body (fmap D.ListDescription . resolve previous)
        "Optional" -> body (fmap D.OptionalDescription . resolve previous)
        "Unit" -> pure D.UnitDescription
        "Checked" -> annotation D.CheckedDescription
        "Documented" -> annotation D.DocumentedDescription
        _ -> fail "Unknown contract description node"
    parseStyle = withObject "field style" $ \fields -> do
      tag <- fields .: "tag" :: Parser Text
      case tag of
        "Named" -> pure D.NamedFields
        "Positional" -> pure D.PositionalFields
        _ -> fail "Unknown field style"

reference :: Eq a => [a] -> a -> Value
reference values value = case elemIndex value values of
  Just index -> toJSON (show index)
  Nothing -> error "Description encoding omitted a dependency"

resolve :: [a] -> Value -> Parser a
resolve previous value = do
  source <- parseJSON value
  case reads source of
    [(index,"")] | index >= (0 :: Integer), index < toInteger (length previous), show index == source ->
      pure (previous !! fromInteger index)
    _ -> fail "Description reference must identify an earlier node"

ordered :: D.Description -> [D.Description]
ordered description = concatMap ordered (children description) ++ [description]
  where
    children (D.NamedDescription _ inner) = [inner]
    children (D.RecordDescription _ _ fields) = [inner | D.FieldDescription _ _ inner <- fields]
    children (D.SumDescription cases) = [inner | D.CaseDescription _ _ _ fields <- cases, D.FieldDescription _ _ inner <- fields]
    children (D.ListDescription inner) = [inner]
    children (D.OptionalDescription inner) = [inner]
    children (D.CheckedDescription _ inner) = [inner]
    children (D.DocumentedDescription _ inner) = [inner]
    children _ = []

identities :: D.Description -> [D.TypeIdentity]
identities (D.ScalarDescription identity _ _ _) = typeTree identity
identities (D.NamedDescription identity _) = typeTree identity
identities _ = []

typeTree :: D.TypeIdentity -> [D.TypeIdentity]
typeTree identity@(D.TypeIdentity _ _ _ arguments) = concatMap typeTree arguments ++ [identity]

tagged :: Text -> Maybe Value -> Value
tagged tag value = object (["tag" .= tag] ++ maybe [] (\v -> ["value" .= v]) value)
