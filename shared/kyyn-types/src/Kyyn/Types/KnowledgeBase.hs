{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.KnowledgeBase (Recipe(..), RecipeId(..), FlowEntryRef(..)) where

import Data.Text (Text)

-- | The name of an identified recipe in the selected root.
newtype RecipeId = RecipeId Text deriving (Eq, Show)

-- | A task guided by instructions or implemented by an authored flow.
-- The containing fact's ID is the recipe's name.
data Recipe
  = OpenAgent { instructions :: Text }
  | ClosedAgent { flow :: FlowEntryRef }
  deriving (Eq, Show)

-- | The qualified name of an authored flow, for example Tasks.reconcile.
newtype FlowEntryRef = FlowEntryRef Text deriving (Eq, Show)
