-- Test-only entry assembled against the real generated calls and dispatcher.
-- The authored flow never chooses observation; this entry does, as the production
-- recipe entry will once the host writer is available.
module ObservedRecipeEntry where

import qualified Agentic.Describe as A
import qualified Annotations
import qualified Flows
import qualified Main as Root
import qualified KyynFactEditCodec
import qualified KyynGuestDispatch
import qualified KyynFlowRuntime
import Kyyn.Runtime.Guest

main :: IO ()
main = runGuest []
  [recipeEntry @Root.Root "Flows.trace" (Annotations.metadata,[]) []
    KyynFactEditCodec.rootCodec KyynGuestDispatch.dispatch
    (KyynFlowRuntime.interpretObserved Flows.trace) (A.describe Flows.trace)]
