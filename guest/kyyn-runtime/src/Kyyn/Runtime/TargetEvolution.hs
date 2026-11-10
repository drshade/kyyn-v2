{-# LANGUAGE GADTs, ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
-- | Target codecs compiled only after preparation selects the retained recipes.
module Kyyn.Runtime.TargetEvolution (RecipeBinding(..), targetBinding) where

import Control.Monad (unless)
import qualified Data.Text as Text
import Kyyn.Contract
import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..), CollectionDecl(..))
import Kyyn.Types.GuestBuild (RecipeReference(..))
import Kyyn.Types.StoredShape
import Kyyn.Recipe.Internal (RecipeType(..))
import qualified Kyyn.Recipe.Internal as Typed
import Kyyn.Evolution.Stored
import Kyyn.Evolution.Target
import Kyyn.Runtime.Contract (runtimeCodec)
import qualified Kyyn.Runtime.Json as Wire

-- The selected method/type reference identifies its generated codec. Open
-- instructions are data, so changing their text does not change state binding.
data RecipeBinding where
  RecipeBinding :: RecipeReference -> RecipeType state -> RecipeBinding

targetBinding :: forall root. Contract root
  => SchemaMetadata -> [RecipeBinding] -> Either ProjectionError (TargetBinding root)
targetBinding (SchemaMetadata _ _ collections) bindings = do
  compiled <- compileContract (contract @root)
  shape <- either (Left . ProjectionError []) Right (storedShape compiled.description)
  let codec = runtimeCodec compiled.codec
      decode (RecordedValue actual value) = do
        unless (canonicalShape actual == shape) (failure "Root shape differs from target")
        either (failure . Text.pack) Right (Wire.decodeWith codec value)
      encode value = Right (RecordedValue shape (Wire.encodeWith codec value))
  pure (TargetBinding [(name,field) | CollectionDecl name field _ <- collections] shape decode encode decodeRecipe encodeRecipe)
  where
    key (OpenAgent _) (Just name) = Right (OpenState name)
    key (ClosedAgent (FlowEntryRef name)) Nothing = Right (ClosedFlow name)
    key _ _ = failure "Invalid stored recipe definition"
    select reference = case [binding | binding@(RecipeBinding actual _) <- bindings, actual == reference] of
      [binding] -> Right binding
      _ -> failure "Recipe definition has no unique target state binding"
    decodeRecipe (StoredRecipe method authored (RecordedValue actual value)) = do
      reference <- key method authored
      RecipeBinding _ (RecipeType name identity shape encode decode) <- select reference
      unless (canonicalShape actual == canonicalShape shape) (failure "Recipe state shape differs from target")
      state <- either (failure . Text.pack) Right (decode value)
      pure (Typed.StoredRecipe method name identity (encode state))
    encodeRecipe (Typed.StoredRecipe method name identity value) = do
      let authored = case method of OpenAgent _ -> Just name; ClosedAgent _ -> Nothing
      reference <- key method authored
      RecipeBinding _ (RecipeType expected expectedIdentity shape encode decode) <- select reference
      unless (name == expected && identity == expectedIdentity) (failure "Recipe state identity differs from target")
      state <- either (failure . Text.pack) Right (decode value)
      pure (StoredRecipe method authored (RecordedValue shape (encode state)))
