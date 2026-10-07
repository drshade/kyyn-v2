module Kyyn.Porcelain.Protocol.RecipePersistence
  ( encodeRecipes, decodeRecipes, encodeRecipeStates, decodeRecipeStates ) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.List (nub, sort, isPrefixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Curation (checkRecipes, recipeId, RecipeId(..))
import Kyyn.Domain.Contract (CheckedContract, contractId, contractShape)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (RelativePath, relativePath, relativeName)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Types.Fact (Fact)
import Kyyn.Types.KnowledgeBase (Recipe)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Protocol.Recipes (recipesShape, legacyRecipeShape, recipesValue, parseRecipes)

encodeRecipes :: DhallHandling :> es => [Fact Recipe] -> Eff es (Either [Diagnostic] ByteString)
encodeRecipes values = case checkRecipes values of
  Left diagnostics -> pure (Left diagnostics)
  Right recipes -> fmap (fmap Text.encodeUtf8) (encodeValue recipesShape (recipesValue recipes))

decodeRecipes :: DhallHandling :> es => Maybe ByteString -> Eff es (Either [Diagnostic] [Fact Recipe])
decodeRecipes Nothing = pure (Right [])
decodeRecipes (Just bytes) = case Text.decodeUtf8' bytes of
  Left problem -> pure (failure (show problem))
  Right source -> do
    decoded <- decodeValue recipesShape source
    compatible <- case decoded of
      Right value -> pure (Right value)
      Left diagnostics -> do
        old <- decodeValue (List (Record [("id",Scalar TextScalar),("value",legacyRecipeShape)])) source
        pure (either (const (Left diagnostics)) Right old)
    pure $ compatible >>= either failure checkRecipes . parseEither parseRecipes
  where failure = Left . pure . errorDiagnostic "recipe.invalid-data"

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
