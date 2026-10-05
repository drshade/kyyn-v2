{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.RootBrowsing
  ( browsingContext, schemaListResult, schemaResult, collectionListResult, collectionResult
  , factListResult, factResult ) where

import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.Text as Text
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Evolution (EvolutionId, evolutionIdName)
import Kyyn.Domain.Git (GitRevision, revisionName)
import Kyyn.Surfaces.Result (Response(..), success)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.SchemaMetadata

browsingContext :: GitRevision -> Maybe EvolutionId -> Response -> Response
browsingContext revision workspace (Response outcome value messages diagnostics) =
  Response outcome enriched (contextLine : messages) diagnostics
  where
    context = object ["revision" .= revisionName revision, "evolution" .= fmap evolutionIdName workspace]
    enriched = case value of Object fields -> Object (Keys.insert "context" context fields); _ -> value
    contextLine = maybe ("Root at " ++ revisionName revision)
      (\identity -> "Evolution " ++ evolutionIdName identity ++ " target (inspected at " ++ revisionName revision ++ ")") workspace

schemaListResult :: RootContract -> Response
schemaListResult root = success
  (object ["kind" .= ("schemas" :: String), "types" .= names]) names
  where names = [haskellType t | t@(Algebraic _ _ _) <- reachableTypes (rootType (rootSchema root))]

schemaResult :: RootContract -> DataType -> Text.Text -> Response
schemaResult root selected rendered = success
  (object ["kind" .= ("schema" :: String), "type" .= haskellType selected,
    "dhallType" .= rendered, "roles" .= roles])
  ([haskellType selected, Text.unpack rendered] ++ roleLines)
  where (roles,roleLines) = fieldRoles (metadataOf (rootSchema root)) selected

collectionListResult :: RootContract -> Response
collectionListResult root = success
  (object ["kind" .= ("collections" :: String), "collections" .= map summary collections])
  (if null collections then ["No collections."] else
    [name ++ " :: " ++ haskellType payload ++ " (root." ++ field ++ ")" |
      CollectionContract name field payload _ <- collections])
  where
    collections = collectionContracts (rootSchema root)
    summary (CollectionContract name field payload _) = object
      ["name" .= name, "rootField" .= field, "payloadType" .= haskellType payload]

collectionResult :: RootContract -> CollectionContract -> Text.Text -> Response
collectionResult root (CollectionContract name field payload _) rendered = success
  (object ["kind" .= ("collection" :: String), "name" .= name, "rootField" .= field,
    "payloadType" .= haskellType payload, "dhallType" .= rendered, "roles" .= roles,
    "references" .= [object ["field" .= f,"collection" .= target] | (f,target) <- references]])
  ([name ++ " (root." ++ field ++ ")", "Payload: " ++ haskellType payload, Text.unpack rendered]
    ++ roleLines ++ ["Reference: " ++ f ++ " → " ++ target | (f,target) <- references])
  where
    metadata@(SchemaMetadata _ _ declarations) = metadataOf (rootSchema root)
    (roles,roleLines) = fieldRoles metadata payload
    references = concat [refs | CollectionDecl actual _ refs <- declarations, actual == name]

fieldRoles :: SchemaMetadata -> DataType -> ([Value],[String])
fieldRoles (SchemaMetadata declarations assignments _) selected = (map asJson roles, map asText roles)
  where
    names = [name | Algebraic name _ _ <- [selected]]
    roles = [(field,name,description,affordance) |
      FieldRole record field role <- assignments, record `elem` names,
      RoleDecl name description affordance <- declarations, role == name]
    asJson (field,name,description,affordance) = object
      ["field" .= field,"role" .= name,"description" .= description,"affordance" .= show affordance]
    asText (field,name,_,affordance) = "Role: " ++ field ++ " — " ++ name ++ " (" ++ show affordance ++ ")"

factListResult :: RootContract -> CollectionContract -> [Fact Value] -> Response
factListResult root (CollectionContract collection _ payload _) facts = success
  (object ["kind" .= ("facts" :: String), "collection" .= collection,
    "facts" .= [object ["id" .= identity,"title" .= title value] | Fact (FactId identity) value <- facts]])
  (if null facts then ["No facts in " ++ collection ++ "."] else
    [identity ++ maybe "" (" — " ++) (title value) | Fact (FactId identity) value <- facts])
  where
    SchemaMetadata declarations assignments _ = metadataOf (rootSchema root)
    names = [name | Algebraic name _ _ <- [payload]]
    titleFields = [field | FieldRole record field role <- assignments, record `elem` names,
      RoleDecl name _ Title <- declarations, name == role]
    title (Object fields) = case titleFields of
      [field] -> Keys.lookup (Key.fromString field) fields >>= titleText
      _ -> Nothing
    title _ = Nothing
    titleText (String value) = Just (Text.unpack value)
    titleText (Object fields)
      | Keys.lookup "tag" fields == Just (String "Some") = Keys.lookup "value" fields >>= titleText
    titleText _ = Nothing

factResult :: String -> Fact Value -> Text.Text -> Response
factResult collection (Fact (FactId identity) value) rendered = success
  (object ["kind" .= ("fact" :: String),"collection" .= collection,"id" .= identity,"value" .= value])
  [collection ++ "/" ++ identity, Text.unpack rendered]
