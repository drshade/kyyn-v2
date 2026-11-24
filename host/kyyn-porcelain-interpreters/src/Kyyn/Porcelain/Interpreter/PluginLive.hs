{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.PluginLive (runPluginLive) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (object, (.=))
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.Deadline (Deadline, withinMicroseconds)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.HttpTransport (HttpTransport)
import Kyyn.Plumbing.Capability.SecretStore (SecretStore)
import Kyyn.Plumbing.Capability.PluginInteraction (Waiting)
import Kyyn.Plumbing.Protocol.PluginHost (decodePluginHostCall)
import Kyyn.Porcelain.Protocol.PluginHost (adapterDeadlineMicroseconds, decodeHostFrame, answerNetwork)
import Kyyn.Porcelain.Protocol.PluginBroker (conversationWithBody)
import Kyyn.Porcelain.Capability.PluginLive
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedMethod(..))

runPluginLive :: (GuestExecution :> es, HttpTransport :> es, SecretStore :> es,
  Waiting :> es, Failure :> es, Deadline :> es, DhallHandling :> es)
  => Eff (PluginLive : es) a -> Eff es a
runPluginLive = interpret $ \_ -> \case
  ExecuteLiveQuery (CheckedValue _ config) (PreparedMethod _ _ input output entry) value -> runExceptT $ do
    _ <- ExceptT (encodeValue (contractShape input) value)
    response <- ExceptT $ Right <$> withinMicroseconds adapterDeadlineMicroseconds
      (conversationWithBody (decodeHostFrame decodePluginHostCall) entry
        (object ["config" .= config,"input" .= value]) answerNetwork)
    case response of
      Nothing -> throwE [errorDiagnostic "plugin.query-timeout" "Live query exceeded its 60-second deadline."]
      Just (Left problem) -> pure (Left problem)
      Just (Right result) -> do
        _ <- ExceptT (encodeValue (contractShape output) result)
        pure (Right (CheckedValue (contractId output) result))
