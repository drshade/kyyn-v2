module Kyyn.Plumbing.Protocol.RecipeEvolution
  ( recipeEvolutionInput, decodeRecipeEvolutionReply, identityRecipeEvolutionSource ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=), (.:), withObject)
import qualified Data.Aeson.KeyMap as Keys
import Data.ByteString (ByteString)
import Data.List (sort)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.DataType (definingModule)
import Kyyn.Domain.EvolutionReport (EvolutionObservation)
import Kyyn.Domain.Recipe (KnowledgeBase(..), ProposedRecipe(..), StoredRecipe(..), proposedRecipe)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Types.Evolution (EvolutionFailure)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Plumbing.Protocol.Evolution (decodeEvolutionReplyWith)

identityRecipeEvolutionSource :: String -> ByteString
identityRecipeEvolutionSource selected = utf8 $ unlines
  ["{-# LANGUAGE OverloadedStrings #-}",
   "module Evolution where", "import Kyyn.Workspace.Evolution",
   "import qualified " ++ definingModule selected ++ " as Before",
   "import qualified Kyyn.Workspace.Before as BeforeCollections",
   "",
   "evolution :: RecipeEvolution Root RecipeState", "evolution = identityEvolution"]

recipeEvolutionInput :: Value -> StoredRecipe -> Value
recipeEvolutionInput facts (StoredRecipe _ _ _ (CheckedValue _ state)) = object ["facts" .= facts,"state" .= state]

decodeRecipeEvolutionReply :: RecipeId -> [Fact StoredRecipe] -> ByteString
  -> Either String (Either EvolutionFailure EvolutionObservation)
decodeRecipeEvolutionReply (RecipeId selected) recipes = decodeEvolutionReplyWith $ withObject "Recipe root" $ \fields -> do
  unless (sort (Keys.keys fields) == ["facts","state"]) (fail "Expected facts and recipe state")
  unless (length [() | Fact (FactId name) _ <- recipes, name == selected] == 1)
    (fail "Selected recipe is missing or ambiguous")
  facts <- fields .: "facts"
  next <- fields .: "state"
  let replace (Fact ident@(FactId name) recipe) = Fact ident $ case proposedRecipe recipe of
        ProposedRecipe method stateType contract state -> ProposedRecipe method stateType contract
          (if name == selected then next else state)
  pure (KnowledgeBase facts (map replace recipes))

utf8 :: String -> ByteString
utf8 = Text.encodeUtf8 . Text.pack
