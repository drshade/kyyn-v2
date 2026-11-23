{-# LANGUAGE OverloadedStrings #-}
-- | The declared execution set, resolved at one selected root revision.
module Kyyn.Domain.FlowClosure (FlowDeclaration(..), flowClosure) where

import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Recipe (RecipeDefinition(..), checkRecipeDefinitions)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase
  (RecipeId(..), FlowEntryRef, Lifetime(..), InteractionBindings(..), ChildReference(..))

data FlowDeclaration = FlowDeclaration
  { recipe :: RecipeId, entry :: FlowEntryRef, bindings :: InteractionBindings }
  deriving (Eq, Show)

-- | Root first, then declared children in order. IDs, not source symbols,
-- distinguish declarations. Recursive and diamond references are visited once.
flowClosure :: [Fact RecipeDefinition] -> RecipeId -> Either [Diagnostic] [FlowDeclaration]
flowClosure definitions selected = do
  _ <- checkRecipeDefinitions definitions
  snd <$> visit [] selected
  where
    visit seen ident@(RecipeId name)
      | name `elem` seen = Right (seen,[])
      | otherwise = case [definition | Fact (FactId actual) definition <- definitions, actual == name] of
          [ClosedRecipe (Interactive configured@(InteractionBindings children)) source] -> do
            (visited,descendants) <- visitChildren (name:seen) children
            pure (visited,FlowDeclaration ident source configured : descendants)
          [_] -> bad name "is not a closed interactive recipe"
          _ -> bad name "does not exist"
    visitChildren seen [] = Right (seen,[])
    visitChildren seen (ChildReference child _ : rest) = do
      (visited,first) <- visit seen child
      (complete,others) <- visitChildren visited rest
      pure (complete,first ++ others)
    bad :: Text -> String -> Either [Diagnostic] a
    bad name reason = Left [errorDiagnostic "flow.declaration" ("Recipe " ++ Text.unpack name ++ " " ++ reason)]
