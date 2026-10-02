{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.ToolExecution (runToolExecution) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn)
import Kyyn.Porcelain.Capability.PluginRead (PluginRead)
import Kyyn.Porcelain.Capability.Tool
import Kyyn.Porcelain.Protocol.ToolBroker (executeToolProgram)

runToolExecution :: (PluginRead :> es, GuestExecution :> es, DhallHandling :> es, Failure :> es, Judgement :> es, ModelTurn :> es)
  => Eff (ToolExecution : es) a -> Eff es a
runToolExecution = interpret $ \_ (ExecuteTool (PreparedTool (ToolDescriptor _ _ input output) program plugins model) arguments) -> runExceptT $ do
  _ <- ExceptT (encodeValue (contractShape input) arguments)
  value <- ExceptT (executeToolProgram program plugins model [] arguments)
  _ <- ExceptT (encodeValue (contractShape output) value)
  pure (CheckedValue (contractId output) value)
