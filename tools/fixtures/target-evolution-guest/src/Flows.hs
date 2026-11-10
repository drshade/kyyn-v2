{-# LANGUAGE DeriveGeneric, DerivingStrategies, DeriveAnyClass #-}
module Flows (review, State(..), oldFlow, OldState(..)) where
import GHC.Generics (Generic)
import Agentic.Contract (Contract)
import qualified Agentic as A
import Kyyn.Recipe
import Kyyn.Agentic (Flow)
import Kyyn.Workspace.FactEdits (RootEdit)
import Schema (Root)
data State = State { runs :: Integer, reviewed :: Bool }
  deriving stock (Generic) deriving anyclass (Contract)
review :: Flow (RecipeInput Root () State) (RecipeProposal RootEdit State)
review = A.act $ \(RecipeInput _ () state) -> pure (RecipeProposal [] state)

-- Names retained in stored definitions, but no longer eligible recipe bindings.
oldFlow :: Integer
oldFlow = 1
data OldState = OldState Integer
