{-# LANGUAGE DeriveGeneric, DerivingStrategies, DeriveAnyClass #-}
module Flows (review, State(..)) where
import GHC.Generics (Generic)
import Agentic.Contract (Contract)
import qualified Agentic as A
import Kyyn.Recipe
import Schema (Root)
data State = State { runs :: Integer, reviewed :: Bool }
  deriving stock (Generic) deriving anyclass (Contract)
review :: A.Agentic Maybe (RecipeInput Root () State) (RecipeProposal () State)
review = A.act $ \(RecipeInput _ () state) -> Just (RecipeProposal [] state)
