module Kyyn.Domain.Recipe
  ( DescriptionFormat(..), KnowledgeBase(..), RecipeDefinition(..)
  , ProposedRecipe(..), StoredRecipe(..), proposedRecipe, recipeMethod, recipeDefinition, proposedDefinition
  , checkRecipeDefinitions
  , RecipeSignature(..)
  ) where

import Data.Aeson (Value)
import Data.Text (Text)
import qualified Data.Text as Text
import Control.Monad (unless)
import Data.List (nub)
import Kyyn.Domain.Curation (recipeId)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Plugin (qualifiedTypeName, bindingModule)
import Kyyn.Domain.Contract (CheckedContract, ContractId, contractId)
import Kyyn.Domain.DataType (DataType)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))

data DescriptionFormat = Tree | Dot | Mermaid deriving (Eq, Show)

data RecipeSignature = RecipeSignature
  { rootType :: DataType, inputType :: DataType, stateType :: DataType }
  deriving (Eq, Show)

data KnowledgeBase root recipe = KnowledgeBase root [Fact recipe] deriving (Eq, Show)

data RecipeDefinition
  = OpenRecipe Text String
  | ClosedRecipe FlowEntryRef
  deriving (Eq, Show)

data ProposedRecipe = ProposedRecipe Recipe String ContractId Value deriving (Eq, Show)

data StoredRecipe = StoredRecipe Recipe String CheckedContract CheckedValue deriving (Eq, Show)

proposedRecipe :: StoredRecipe -> ProposedRecipe
proposedRecipe (StoredRecipe method stateType contract (CheckedValue _ value)) =
  ProposedRecipe method stateType (contractId contract) value

recipeMethod :: RecipeDefinition -> Recipe
recipeMethod (OpenRecipe instructions _) = OpenAgent instructions
recipeMethod (ClosedRecipe entry) = ClosedAgent entry

recipeDefinition :: StoredRecipe -> RecipeDefinition
recipeDefinition (StoredRecipe method name _ _) = case method of
  OpenAgent instructions -> OpenRecipe instructions name
  ClosedAgent entry -> ClosedRecipe entry

proposedDefinition :: ProposedRecipe -> RecipeDefinition
proposedDefinition (ProposedRecipe method name _ _) = case method of
  OpenAgent instructions -> OpenRecipe instructions name
  ClosedAgent entry -> ClosedRecipe entry

checkRecipeDefinitions :: [Fact RecipeDefinition] -> Either [Diagnostic] [Fact RecipeDefinition]
checkRecipeDefinitions definitions = do
  let names = [name | Fact (FactId name) _ <- definitions]
  unless (length names == length (nub names)) (bad "Duplicate recipe IDs")
  mapM_ (\(Fact (FactId name) definition) -> do
    _ <- checked (recipeId (Text.unpack name))
    case definition of
      OpenRecipe _ "()" -> pure ()
      OpenRecipe _ stateType -> checked (qualifiedTypeName stateType) >> pure ()
      ClosedRecipe (FlowEntryRef entry) -> checked (bindingModule (Text.unpack entry)) >> pure ()) definitions
  pure definitions
  where
    checked = either bad Right
    bad message = Left [errorDiagnostic "recipe.definition-invalid" message]
