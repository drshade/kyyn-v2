{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.Flow (runFlow) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Git (TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Plumbing.Capability.Git (Git, readTreeAt)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation, readRootRecipes)
import Kyyn.Porcelain.Capability.FlowPreparation (FlowPreparation, prepareInteractiveFlow)
import Kyyn.Porcelain.Capability.FlowStore (FlowStore, startPreparedInstance)
import Kyyn.Porcelain.Capability.Flow

runFlow :: (Git :> es, RootStore :> es, FlowPreparation :> es, FlowStore :> es)
  => Eff (Flow : es) a -> Eff es a
runFlow = interpret $ \_ (StartFlowAt kb revision recipe key input) -> start kb revision recipe key input
  where
    start kb@(KnowledgeBase repository _) revision recipe key input = runExceptT $ do
      if Text.null (Text.strip key) then throwE [errorDiagnostic "flow.key" "Supply a nonempty caller key"] else pure ()
      location <- either (throwE . pure . errorDiagnostic "kb.path") pure (rootLocation kb)
      source <- ExceptT (readTreeAt repository revision (Subtree location))
      recipes <- ExceptT (readRootRecipes source)
      prepared <- ExceptT (prepareInteractiveFlow revision source recipes recipe input)
      ExceptT (either (Left . pure . flowProblem) Right <$> startPreparedInstance Nothing key prepared)
    
