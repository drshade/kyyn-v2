{-# LANGUAGE DeriveGeneric, DerivingStrategies, DeriveAnyClass #-}
module AfterFlows (review, helper) where
import GHC.Generics (Generic)
import Agentic.Contract (Contract)
import qualified Agentic as A
import Kyyn.Recipe
import After (Root)
data State = State { runs :: Integer } deriving stock (Generic) deriving anyclass (Contract)
review :: A.Agentic Maybe (RecipeInput Root () State) (RecipeProposal () State)
review = A.act $ \(RecipeInput _ () state) -> Just (RecipeProposal [] state)
helper :: Integer
helper = 1
