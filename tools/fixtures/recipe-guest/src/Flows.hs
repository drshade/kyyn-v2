module Flows (review) where

import GHC.Generics (Generic)
import Agentic.Contract (Contract)
import qualified Agentic as A
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
