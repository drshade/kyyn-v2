{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies #-}
module RecipeTypeProvider (Root, Other, flow, initial) where
import GHC.Generics (Generic)
import Agentic.Contract (Contract)
import qualified Agentic as A
import Kyyn.Recipe

data Root = Root deriving stock (Generic) deriving anyclass (Contract)
data Other = Other deriving stock (Generic) deriving anyclass (Contract)
data Hidden = Hidden { count :: Integer } deriving stock (Generic) deriving anyclass (Contract)
initial :: Hidden
initial = Hidden 1
flow :: A.Agentic Maybe (RecipeInput Root () Hidden) (RecipeProposal () Hidden)
flow = A.act $ \(RecipeInput _ () state) -> Just (RecipeProposal [] state)
