module Kyyn.Types.KnowledgeBase (KnowledgeBase(..), Recipe(..)) where

import Kyyn.Types.Fact (Fact)

-- | Domain facts and the identified recipes explaining how to work with them.
data KnowledgeBase a = KnowledgeBase a [Fact Recipe] deriving (Eq, Show)

-- | Instructions for an agent performing a named task in the knowledge base.
-- The containing fact's ID is the recipe's name.
data Recipe = Recipe { recipeInstructions :: String } deriving (Eq, Show)
