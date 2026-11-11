{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Porcelain.Protocol.SnapshotWire (encodeSnapshotWire, decodeSnapshotWire) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (nub)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.StoredSnapshot
import Kyyn.Domain.Recipe (RecipeDefinition(..))
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.StoragePath (encodeComponent)
import Kyyn.Types.SnapshotWire
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Data.Aeson (toJSON, object, (.=))
import qualified Data.Aeson.Key as Key
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Porcelain.Protocol.StoredSnapshot (readStoredSnapshot)
import Kyyn.Porcelain.Protocol.RecipePersistence (encodeRecipes)

encodeSnapshotWire :: StoredSnapshot -> Either String SnapshotWire
encodeSnapshotWire (StoredSnapshot fields collections recipes) = SnapshotWire
  <$> traverse (\(name,value) -> (name,) <$> encode value) fields
  <*> traverse (\(name,members) -> (name,) <$> traverse (\(Fact (FactId identity) value) -> (identity,) <$> encode value) members) collections
  <*> traverse (\(Fact (FactId identity) (RecordedRecipe definition state)) -> do
    value <- encode state
    pure (identity,RecipeWire (case definition of
      OpenRecipe instructions name -> OpenWire instructions (Text.pack name)
      ClosedRecipe (FlowEntryRef flow) -> ClosedWire flow) value)) recipes
  where encode (RecordedValue shape value) = ValueWire <$> storageShape shape <*> pure value

-- Guest-produced observations are untrusted. Reuse the same hermetic storage
-- reader as capture, including shape/value agreement, paths and identity checks.
decodeSnapshotWire :: DhallHandling :> es => SnapshotWire -> Eff es (Either [Diagnostic] StoredSnapshot)
decodeSnapshotWire (SnapshotWire fields collections recipes) = runExceptT $ do
  unique "fields" (map fst fields)
  unique "collections" (map fst collections)
  unique "recipes" (map fst recipes)
  let residualShape = Record [(Text.unpack name,inferredShape shape) | (name,ValueWire shape _) <- fields]
      residualValue = object [Key.fromText name .= value | (name,ValueWire _ value) <- fields]
  residual <- file "facts/root.dhall" residualShape residualValue
  members <- fmap concat $ traverse (\(name,values) -> do
    unique "members" (map fst values)
    let prefix = "facts/" ++ encodeComponent name ++ "/"
    index <- file (prefix ++ "index.dhall") (List (Scalar TextScalar)) (toJSON (map fst values))
    facts <- traverse (\(identity,ValueWire shape value) ->
      file (prefix ++ encodeComponent identity ++ ".dhall") (inferredShape shape) value) values
    pure (index:facts)) collections
  let definitions = [Fact (FactId identity) (case definition of
        OpenWire instructions name -> OpenRecipe instructions (Text.unpack name)
        ClosedWire flow -> ClosedRecipe (FlowEntryRef flow)) | (identity,RecipeWire definition _) <- recipes]
  definitionBytes <- ExceptT (encodeRecipes definitions)
  definitionPath <- checked (relativePath "recipes.dhall")
  states <- traverse (\(identity,RecipeWire _ (ValueWire shape value)) ->
    file ("recipes/" ++ Text.unpack identity ++ "/state.dhall") (inferredShape shape) value) recipes
  tree <- checked (fileTree (residual : (definitionPath,definitionBytes) : members ++ states))
  ExceptT (readStoredSnapshot tree)
  where
    file name shape value = do
      path <- checked (relativePath name)
      encoded <- ExceptT (encodeValue shape value)
      pure (path,Text.encodeUtf8 encoded)
    unique label values = unless (length values == length (nub values)) (bad ("Duplicate " ++ label))
    checked = either bad pure
    bad = throwE . pure . errorDiagnostic "evolution.snapshot-wire"
