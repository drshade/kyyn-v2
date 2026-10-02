{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.RecipeExecution (runRecipeExecution) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson.Types (parseEither)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Root (Root(..), CheckedValue(..))
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn)
import Kyyn.Plumbing.Protocol.Recipe (recipeSources, recipeInputValue)
import Kyyn.Plumbing.Protocol.FactProposal (proposalShape, parseProposal)
import Kyyn.Porcelain.Capability.RootStore (RootStore, loadRootValueForChecking)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation, prepareToolBindings)
import Kyyn.Porcelain.Capability.PluginRead (PluginRead)
import Kyyn.Porcelain.Capability.RecipeExecution
import Kyyn.Porcelain.Protocol.ToolBindings (pluginBindings)
import Kyyn.Porcelain.Protocol.ToolBroker (executeToolProgram)
import Kyyn.Porcelain.Protocol.ModelConfiguration (readModelConfiguration)

runRecipeExecution :: (RootStore :> es, ToolPreparation :> es, GuestCompilation :> es,
  GuestExecution :> es, PluginRead :> es, Failure :> es, Judgement :> es, ModelTurn :> es, DhallHandling :> es)
  => Eff (RecipeExecution : es) a -> Eff es a
runRecipeExecution = interpret $ \_ (ExecuteRecipeFlow root@(Root contract _ code _ _) plugins entry recipe captured) -> runExceptT $ do
  (sources,_) <- ExceptT (prepareToolBindings code plugins)
  let (interfaces,instances) = pluginBindings plugins
      checked = either (throwE . pure . errorDiagnostic "recipe.execution") pure
  programSources <- checked (recipeSources contract entry interfaces instances sources)
  program <- ExceptT (compileGuest programSources)
  model <- ExceptT (readModelConfiguration code)
  CheckedValue _ value <- ExceptT (loadRootValueForChecking root)
  result <- ExceptT (executeToolProgram program plugins model (map snd captured)
    (recipeInputValue recipe value (map fst captured)))
  shape <- checked (proposalShape contract)
  _ <- ExceptT (encodeValue shape result)
  checked (parseEither parseProposal result)
