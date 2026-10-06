{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.KnowledgeBase (KnowledgeBase(..), Recipe(..), FlowEntryRef(..)) where

import Data.Text (Text)

import Kyyn.Types.Fact (Fact)

-- | Domain facts and the identified recipes explaining how to work with them.
data KnowledgeBase a = KnowledgeBase a [Fact Recipe] deriving (Eq, Show)

-- | A task guided by instructions or implemented by an authored flow.
-- The containing fact's ID is the recipe's name.
data Recipe
  = OpenAgent { instructions :: Text }
  | ClosedAgent { flow :: FlowEntryRef }
  deriving (Eq, Show)

-- | The qualified name of an authored flow, for example Tasks.reconcile.
newtype FlowEntryRef = FlowEntryRef Text deriving (Eq, Show)
