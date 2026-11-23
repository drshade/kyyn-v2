module Kyyn.Domain.Recipe
  ( DescriptionFormat(..), KnowledgeBase(..), RecipeDefinition(..)
  , ProposedRecipe(..), StoredRecipe(..), proposedRecipe, recipeMethod, recipeDefinition, proposedDefinition
  , checkRecipeDefinitions, RecipeId(..), recipeId
  , RecipeSignature(..)
  ) where

import Data.Aeson (Value)
import Data.Text (Text)
import qualified Data.Text as Text
import Control.Monad (unless)
import Data.List (nub)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Plugin (qualifiedTypeName, bindingModule, bindingName)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.DataType (DataType)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Guest (DescriptionFormat(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (Lifetime(..), InteractionBindings(..), ChildReference(..), EventReference(EventReference), Recipe(..), RecipeId(..), FlowEntryRef(..))

recipeId :: String -> Either String RecipeId
recipeId value = either (Left . ("Invalid recipe name: " ++)) (const (Right (RecipeId (Text.pack value)))) (bindingName value)


data RecipeSignature = RecipeSignature
  { rootType :: DataType, inputType :: DataType, stateType :: DataType }
  deriving (Eq, Show)

data KnowledgeBase root recipe = KnowledgeBase root [Fact recipe] deriving (Eq, Show)

data RecipeDefinition
  = OpenRecipe Lifetime Text String
  | ClosedRecipe Lifetime FlowEntryRef
  deriving (Eq, Show)

data ProposedRecipe = ProposedRecipe RecipeDefinition Value deriving (Eq, Show)

data StoredRecipe = StoredRecipe Recipe String CheckedContract CheckedValue deriving (Eq, Show)

proposedRecipe :: StoredRecipe -> ProposedRecipe
proposedRecipe recipe@(StoredRecipe _ _ _ (CheckedValue _ value)) =
  ProposedRecipe (recipeDefinition recipe) value

recipeMethod :: RecipeDefinition -> Recipe
recipeMethod (OpenRecipe lifetime instructions _) = OpenAgent lifetime instructions
recipeMethod (ClosedRecipe lifetime entry) = ClosedAgent lifetime entry

recipeDefinition :: StoredRecipe -> RecipeDefinition
recipeDefinition (StoredRecipe method name _ _) = case method of
  OpenAgent lifetime instructions -> OpenRecipe lifetime instructions name
  ClosedAgent lifetime entry -> ClosedRecipe lifetime entry

proposedDefinition :: ProposedRecipe -> RecipeDefinition
proposedDefinition (ProposedRecipe definition _) = definition

checkRecipeDefinitions :: [Fact RecipeDefinition] -> Either [Diagnostic] [Fact RecipeDefinition]
checkRecipeDefinitions definitions = do
  let names = [name | Fact (FactId name) _ <- definitions]
  unless (length names == length (nub names)) (bad "Duplicate recipe IDs")
  mapM_ (\(Fact (FactId name) definition) -> do
    _ <- checked (recipeId (Text.unpack name))
    case definition of
      OpenRecipe (Interactive _) _ _ -> bad "Interactive open recipes are not supported"
      OpenRecipe _ _ "()" -> pure ()
      OpenRecipe _ _ stateType -> checked (qualifiedTypeName stateType) >> pure ()
      ClosedRecipe _ (FlowEntryRef entry) -> checked (bindingModule (Text.unpack entry)) >> pure ()) definitions
  mapM_ checkChildren definitions
  pure definitions
  where
    checkChildren (Fact (FactId parent) (ClosedRecipe (Interactive (InteractionBindings refs selectedEvents)) _)) = do
      unless (length refs == length (nub refs)) (bad ("Recipe " <> Text.unpack parent <> ": duplicate child declarations"))
      mapM_ (checkChild parent) refs
      let identities = [(p,i,m) | EventReference p _ i m <- selectedEvents]
      unless (length identities == length (nub identities)) (bad ("Recipe " <> Text.unpack parent <> ": duplicate event declarations"))
    checkChildren _ = pure ()
    checkChild parent (ChildReference (RecipeId child) expected) =
      case [definition | Fact (FactId name) definition <- definitions, name == child] of
        [ClosedRecipe (Interactive _) actual] | actual == expected -> pure ()
        [ClosedRecipe (Interactive _) _] -> childBad "uses a different flow definition"
        [_] -> childBad "is not a closed interactive recipe"
        [] -> childBad "does not exist in the target recipes"
        _ -> childBad "is duplicated"
      where childBad reason = bad ("Recipe " <> Text.unpack parent <> ": child " <> Text.unpack child <> " " <> reason)
    checked = either bad Right
    bad message = Left [errorDiagnostic "recipe.definition-invalid" message]
