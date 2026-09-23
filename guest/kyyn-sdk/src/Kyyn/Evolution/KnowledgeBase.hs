{-# LANGUAGE RankNTypes #-}
module Kyyn.Evolution.KnowledgeBase
  ( KnowledgeBase(..), Recipe(..), facts, recipes, onFacts ) where

import Kyyn.Types.KnowledgeBase (KnowledgeBase(..), Recipe(..))
import Kyyn.Types.Evolution (EvolutionFailure)
import Kyyn.Edit.Internal (Collection(..))
import Kyyn.Optics (Lens, lens)

-- | Focus the domain facts, preserving recipes even when the facts type changes.
facts :: Lens (KnowledgeBase a) (KnowledgeBase b) a b
facts = lens (\(KnowledgeBase value _) -> value)
  (\(KnowledgeBase _ tasks) value -> KnowledgeBase value tasks)

-- | Edit recipes by name using within, append, update, current and remove.
recipes :: Collection (KnowledgeBase a) Recipe
recipes = Collection "recipes" (lens (\(KnowledgeBase _ tasks) -> tasks)
  (\(KnowledgeBase value _) tasks -> KnowledgeBase value tasks))

-- | Apply a fallible domain transformation while keeping recipes unchanged.
onFacts :: (a -> Either EvolutionFailure b)
  -> KnowledgeBase a -> Either EvolutionFailure (KnowledgeBase b)
onFacts transform (KnowledgeBase value tasks) =
  (\after -> KnowledgeBase after tasks) <$> transform value
