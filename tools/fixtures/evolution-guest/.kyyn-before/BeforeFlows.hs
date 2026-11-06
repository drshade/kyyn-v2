{-# LANGUAGE DeriveGeneric, DerivingStrategies, DeriveAnyClass #-}
module BeforeFlows (review) where
import GHC.Generics (Generic)
import Agentic.Contract (Contract)
import qualified Agentic as A
import Kyyn.Recipe
import Before (Root)
data State = State { reviewed :: Integer } deriving stock (Generic) deriving anyclass (Contract)
review :: A.Agentic Maybe (RecipeInput Root () State) (RecipeProposal () State)
review = A.act $ \(RecipeInput _ () state) -> Just (RecipeProposal [] state)
