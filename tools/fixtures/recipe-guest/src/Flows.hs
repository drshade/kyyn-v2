module Flows (review, recursive, invalidRecursive, observedReview, trace, observedTrace) where

import GHC.Generics (Generic)
import Data.Text (Text)
import Agentic.Contract (Contract)
import qualified Agentic as A
import Control.Monad.Trans.Except (ExceptT(..))
import Kyyn.Agentic (Flow, interpretObserved)
import Kyyn.Connectors (files)
import qualified Kyyn.Plugins.P_local_file.Files as Files
import Kyyn.Recipe
import Kyyn.Evolution (Rationale(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Workspace.FactEdits (RootEdit(..))
import qualified Kyyn.Workspace.Target
import qualified Kyyn.Workspace.Evolution
import Main (Root, Item(..))

data State = State { runs :: Integer }
  deriving stock (Generic) deriving anyclass (Contract)

review :: Flow (RecipeInput Root () State) (RecipeProposal RootEdit State)
review = A.act $ \(RecipeInput _ () (State runs)) -> do
  count <- ExceptT (Files.count files ())
  pure (RecipeProposal
    [ProposedStep (Rationale "One recipe step" [])
      [Edit_items (Append (Fact (FactId "recipe-item") (Item 1)))]]
    (State (runs + count + 1)))

-- Description traverses finite recursive definitions without invoking a model.
recursive :: Flow (RecipeInput Root () State) (RecipeProposal RootEdit State)
recursive = A.arr (const ("input" :: Text)) A.>>> nested A.>>> A.arr proposal
  where
    nested :: Flow Text Text
    nested = A.draftWith [A.recursiveTool $ \self ->
      A.tool "again" "Recursive helper" (A.draftWith [self] "Continue" :: Flow Text Text)] "Start"
    proposal _ = RecipeProposal [] (State 0)

-- Aliasing a binder member is an upstream structural error, not a model error.
invalidRecursive :: Flow (RecipeInput Root () State) (RecipeProposal RootEdit State)
invalidRecursive = A.arr (const ("input" :: Text)) A.>>> nested A.>>> A.arr proposal
  where
    nested :: Flow Text Text
    nested = A.draftWith [A.recursiveTool id] "Invalid recursive definition"
    proposal _ = RecipeProposal [] (State 0)

-- Test the generated observer and dispatch before production activation. The
-- inner review invocation is the observed run; the wrapper itself is unobserved.
observedReview :: Flow (RecipeInput Root () State) (RecipeProposal RootEdit State)
observedReview = A.act (ExceptT . interpretObserved review)

trace :: Flow (RecipeInput Root Bool State) (RecipeProposal RootEdit State)
trace = A.arr (const ([Left 0, Right 0] :: [Either Int Int]))
  A.>>> A.each ((A.repeatUntil (>= 2) (A.arr (+1))) A.||| A.arr (+2))
  A.>>> A.arr (const ("input" :: Text))
  A.>>> (A.draftWith [A.tool "helper" "Nested helper" (A.draft "inner" :: Flow Text Text)] "outer" :: Flow Text Text)
  A.>>> A.arr (const (RecipeProposal [] (State 1)))

observedTrace :: Flow (RecipeInput Root Bool State) (RecipeProposal RootEdit State)
observedTrace = A.act (ExceptT . interpretObserved trace)
