module Flows (review, recursive, invalidRecursive, trace, waiting) where

import GHC.Generics (Generic)
import Data.Text (Text)
import Agentic.Contract (Contract)
import qualified Agentic as A
import qualified Agentic.Codec as C
import qualified Agentic.Schema as S
import qualified Agentic.Value as V
import Control.Monad.Trans.Except (ExceptT(..))
import Kyyn.Agentic (Flow)
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

trace :: Flow (RecipeInput Root Bool State) (RecipeProposal RootEdit State)
trace = A.arr (const ([Left 0, Right 0] :: [Either Int Int]))
  A.>>> A.each ((A.repeatUntil (>= 2) (A.arr (+1))) A.||| A.arr (+2))
  A.>>> A.arr (const ("input" :: Text))
  A.>>> (A.draftWith [A.tool "helper" "Nested helper" (A.draft "inner" :: Flow Text Text)] "outer" :: Flow Text Text)
  A.>>> A.arr (const (RecipeProposal [] (State 1)))

-- The connector must run only on the first attempt; the reply completes the proposal.
waiting :: Flow (RecipeInput Root () State) (RecipeProposal RootEdit State)
waiting = A.arr (\(RecipeInput _ () (State runs)) -> runs)
  A.>>> A.durably integer number (\_ runs -> do
    count <- ExceptT (Files.count files ())
    pure (fromInteger (runs + count)))
  A.>>> A.arr round
  A.>>> A.await integer integer
  A.>>> A.arr (\reply -> RecipeProposal [] (State reply))
  where
    number = C.primitive S.SNumber V.Number $ \value -> case value of
      V.Number n -> Right n
      _ -> Left "Expected floating-point result, not an integer"
    integer = C.primitive S.SInteger V.Integer $ \value -> case value of
      V.Integer n -> Right n
      _ -> Left "Expected integer reply"
