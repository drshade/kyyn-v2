module Kyyn.Runtime.Recipe (recipeInputCodec) where

import Kyyn.Recipe
import Kyyn.Runtime.Json

recipeInputCodec :: Codec root -> Codec (RecipeInput root)
recipeInputCodec rootCodec = Codec encode decode
  where
    encode (RecipeInput (RecipeId name) root pending) = record
      [("recipe",encodeWith stringCodec name),("root",encodeWith rootCodec root),
       ("pending",encodeWith (listCodec pendingCodec) pending)]
    decode value = do
      values <- fields ["recipe","root","pending"] value
      RecipeInput <$> (RecipeId <$> field "recipe" stringCodec values)
        <*> field "root" rootCodec values <*> field "pending" (listCodec pendingCodec) values

pendingCodec :: Codec PendingEvidence
pendingCodec = Codec encode decode
  where
    encode (PendingEvidence scope changes) = record
      [("scope",encodeWith scopeCodec scope),
       ("changes",encodeWith (listCodec changeCodec) changes)]
    decode value = do
      values <- fields ["scope","changes"] value
      scope <- field "scope" scopeCodec values
      PendingEvidence scope <$> field "changes" (listCodec changeCodec) values
scopeCodec :: Codec EvidenceScope
scopeCodec = Codec encode decode
  where
    encode (EvidenceScope plugin instanceName fetch) = record
      [("plugin",text plugin),("instance",text instanceName),("fetch",text fetch)]
    decode value = do
      values <- fields ["plugin","instance","fetch"] value
      EvidenceScope <$> field "plugin" stringCodec values <*> field "instance" stringCodec values <*> field "fetch" stringCodec values
    text = encodeWith stringCodec

changeCodec :: Codec PendingChange
changeCodec = Codec encode decode
  where
    encode change = case change of
      New (EvidenceId name) -> tagged "New" (Just (encodeWith stringCodec name))
      Updated (EvidenceId name) -> tagged "Updated" (Just (encodeWith stringCodec name))
      Removed (EvidenceId name) -> tagged "Removed" (Just (encodeWith stringCodec name))
    decode value = do
      (name,payload) <- variant value
      item <- maybe (Left "Pending change needs an evidence ID") (fmap EvidenceId . decodeWith stringCodec) payload
      case name of
        "New" -> Right (New item)
        "Updated" -> Right (Updated item)
        "Removed" -> Right (Removed item)
        _ -> Left "Unknown pending change"
