{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Porcelain.Protocol.RecipePersistence
  ( encodeRecipes, decodeRecipes, encodeRecipeStates, decodeRecipeStates
  , encodeStoredRecipes, decodeStoredRecipes, encodeRecipeContracts, decodeRecipeContracts ) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (object, (.=), (.:), withObject, toJSON)
import Data.Aeson.Types (parseEither, parseJSON)
import Data.ByteString (ByteString)
import Data.List (nub, sort, isPrefixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Recipe (recipeId, RecipeId(..))
import Kyyn.Domain.Recipe (RecipeDefinition, StoredRecipe(..), recipeDefinition, recipeMethod, checkRecipeDefinitions)
import Kyyn.Domain.Contract (CheckedContract, contractId, contractShape)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (RelativePath, relativePath, relativeName)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Protocol.Recipes (recipesShape, recipesValue, parseRecipes)
import Kyyn.Plumbing.Protocol.EvolutionRecord.Contract (snapshotShape, checkedSnapshotValue, restoreCheckedSnapshot)

encodeRecipes :: DhallHandling :> es => [Fact RecipeDefinition] -> Eff es (Either [Diagnostic] ByteString)
encodeRecipes values = case checkRecipeDefinitions values of
  Left diagnostics -> pure (Left diagnostics)
  Right recipes -> fmap (fmap Text.encodeUtf8) (encodeValue recipesShape (recipesValue recipes))

decodeRecipes :: DhallHandling :> es => Maybe ByteString -> Eff es (Either [Diagnostic] [Fact RecipeDefinition])
decodeRecipes Nothing = pure (Right [])
decodeRecipes (Just bytes) = case Text.decodeUtf8' bytes of
  Left problem -> pure (failure (show problem))
  Right source -> do
    decoded <- decodeValue recipesShape source
    pure $ decoded >>= either failure checkRecipeDefinitions . parseEither parseRecipes
  where failure = Left . pure . errorDiagnostic "recipe.invalid-data"

encodeStoredRecipes :: DhallHandling :> es
  => [Fact StoredRecipe] -> Eff es (Either [Diagnostic] FileTree)
encodeStoredRecipes recipes = runExceptT $ do
  definitions <- ExceptT (encodeRecipes [Fact identity (recipeDefinition recipe) | Fact identity recipe <- recipes])
  states <- ExceptT (encodeRecipeStates [(RecipeId name,contract,value) |
    Fact (FactId name) (StoredRecipe _ _ contract value) <- recipes])
  location <- checked (relativePath "recipes.dhall")
  checked (fileTree ((location,definitions) : files states))

decodeStoredRecipes :: DhallHandling :> es
  => [(Fact RecipeDefinition, String, CheckedContract)] -> FileTree
  -> Eff es (Either [Diagnostic] [Fact StoredRecipe])
decodeStoredRecipes definitions tree = runExceptT $ do
  _ <- ExceptT (pure (checkRecipeDefinitions [definition | (definition,_,_) <- definitions]))
  states <- ExceptT (decodeRecipeStates [(RecipeId name,contract) |
    (Fact (FactId name) _,_,contract) <- definitions] tree)
  traverse (\(Fact identity@(FactId name) definition,stateType,contract) -> do
    value <- maybe (bad ("Missing state for " ++ Text.unpack name)) pure (lookup (RecipeId name) states)
    pure (Fact identity (StoredRecipe (recipeMethod definition) stateType contract value))) definitions

encodeRecipeContracts :: DhallHandling :> es
  => [Fact StoredRecipe] -> Eff es (Either [Diagnostic] ByteString)
encodeRecipeContracts recipes = fmap (fmap Text.encodeUtf8) $ encodeValue recipeContractsShape
  (toValue recipes)
  where
    toValue entries = toJSON [object ["id" .= name,"stateType" .= stateType,
      "contract" .= checkedSnapshotValue contract] |
      Fact (FactId name) (StoredRecipe _ stateType contract _) <- entries]

decodeRecipeContracts :: DhallHandling :> es
  => ByteString -> Eff es (Either [Diagnostic] [(FactId,String,CheckedContract)])
decodeRecipeContracts bytes = runExceptT $ do
  source <- checked (either (Left . show) Right (Text.decodeUtf8' bytes))
  value <- ExceptT (decodeValue recipeContractsShape source)
  restored <- checked (parseEither (\v -> parseJSON v >>= traverse
    (withObject "Recipe contract" $ \fields -> do
      name <- FactId <$> fields .: "id"
      stateType <- fields .: "stateType"
      contract <- fields .: "contract" >>= restoreCheckedSnapshot
      pure ((name,stateType,) <$> contract))) value)
  ExceptT (pure (sequence restored))

recipeContractsShape :: Shape
recipeContractsShape = List (Record [("id",Scalar TextScalar),("stateType",Scalar TextScalar),("contract",snapshotShape)])

encodeRecipeStates :: DhallHandling :> es
  => [(RecipeId, CheckedContract, CheckedValue)] -> Eff es (Either [Diagnostic] FileTree)
encodeRecipeStates entries = runExceptT $ do
  paths <- checked (statePaths [ident | (ident,_,_) <- entries])
  encoded <- traverse (\(path,(_,contract,CheckedValue identity value)) -> do
    unless (identity == contractId contract) (bad "State value belongs to a different recipe contract")
    source <- ExceptT (encodeValue (contractShape contract) value)
    pure (path,Text.encodeUtf8 source)) (zip paths entries)
  checked (fileTree encoded)

decodeRecipeStates :: DhallHandling :> es
  => [(RecipeId, CheckedContract)] -> FileTree
  -> Eff es (Either [Diagnostic] [(RecipeId, CheckedValue)])
decodeRecipeStates entries tree = runExceptT $ do
  paths <- checked (statePaths (map fst entries))
  let actual = [path | (path,_) <- files tree,
        relativeName path == "recipes" || "recipes/" `isPrefixOf` relativeName path]
  unless (sort paths == sort actual) (bad "Each recipe must have exactly one recipes/<id>/state.dhall file")
  traverse (\(path,(ident,contract)) -> do
    bytes <- maybe (bad ("Missing state: " ++ relativeName path)) pure (lookup path (files tree))
    source <- checked (either (Left . show) Right (Text.decodeUtf8' bytes))
    value <- ExceptT (decodeValue (contractShape contract) source)
    pure (ident,CheckedValue (contractId contract) value)) (zip paths entries)

statePaths :: [RecipeId] -> Either String [RelativePath]
statePaths identities = do
  unless (length identities == length (nub identities)) (Left "Duplicate recipe IDs")
  traverse (\(RecipeId name) -> do
    _ <- recipeId (Text.unpack name)
    relativePath ("recipes/" ++ Text.unpack name ++ "/state.dhall")) identities

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either bad pure

bad :: String -> ExceptT [Diagnostic] (Eff es) a
bad = throwE . pure . errorDiagnostic "recipe.state-invalid"
