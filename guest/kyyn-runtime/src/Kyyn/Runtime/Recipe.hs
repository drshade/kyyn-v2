module Kyyn.Runtime.Recipe (recipeInputCodec) where

import Kyyn.Recipe
import Kyyn.Runtime.Json

recipeInputCodec :: Codec root -> Codec (RecipeInput root)
recipeInputCodec rootCodec = Codec encode decode
  where
    encode (RecipeInput (RecipeId name) root pending) = record
      [("recipe",encodeWith textCodec name),("root",encodeWith rootCodec root),
       ("pending",encodeWith (listCodec pendingCodec) pending)]
    decode value = do
      values <- fields ["recipe","root","pending"] value
      RecipeInput <$> (RecipeId <$> field "recipe" textCodec values)
        <*> field "root" rootCodec values <*> field "pending" (listCodec pendingCodec) values

pendingCodec :: Codec PendingEvidence
pendingCodec = Codec encode decode
  where
    encode (PendingEvidence scope changes) = record
      [("scope",encodeWith scopeCodec scope),
       ("batch",tagged "Changes" (Just (encodeWith (listCodec changeCodec) changes)))]
    encode (Reconciliation scope ids) = record
      [("scope",encodeWith scopeCodec scope),
       ("batch",tagged "Reconciliation" (Just (encodeWith (listCodec idCodec) ids)))]
    decode value = do
      values <- fields ["scope","batch"] value
      scope <- field "scope" scopeCodec values
      batch <- field "batch" (Codec id Right) values
      (tag,payload) <- variant batch
      case (tag,payload) of
        ("Changes",Just changes) -> PendingEvidence scope <$> decodeWith (listCodec changeCodec) changes
        ("Reconciliation",Just ids) -> Reconciliation scope <$> decodeWith (listCodec idCodec) ids
        _ -> Left "Invalid recipe evidence batch"

idCodec :: Codec EvidenceId
idCodec = Codec (\(EvidenceId name) -> encodeWith textCodec name) (fmap EvidenceId . decodeWith textCodec)

scopeCodec :: Codec EvidenceScope
scopeCodec = Codec encode decode
  where
    encode (EvidenceScope plugin instanceName fetch) = record
      [("plugin",text plugin),("instance",text instanceName),("fetch",text fetch)]
    decode value = do
      values <- fields ["plugin","instance","fetch"] value
      EvidenceScope <$> field "plugin" textCodec values <*> field "instance" textCodec values <*> field "fetch" textCodec values
    text = encodeWith textCodec

changeCodec :: Codec PendingChange
changeCodec = Codec encode decode
  where
    encode change = case change of
      New (EvidenceId name) -> tagged "New" (Just (encodeWith textCodec name))
      Updated (EvidenceId name) -> tagged "Updated" (Just (encodeWith textCodec name))
      Removed (EvidenceId name) -> tagged "Removed" (Just (encodeWith textCodec name))
    decode value = do
      (name,payload) <- variant value
      item <- maybe (Left "Pending change needs an evidence ID") (fmap EvidenceId . decodeWith textCodec) payload
      case name of
        "New" -> Right (New item)
        "Updated" -> Right (Updated item)
        "Removed" -> Right (Removed item)
        _ -> Left "Unknown pending change"
