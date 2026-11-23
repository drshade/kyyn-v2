{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.PluginEvent (runPluginEvent) where

import Data.Aeson (object, (.=))
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.HttpTransport (HttpTransport)
import Kyyn.Plumbing.Capability.SecretStore (SecretStore)
import Kyyn.Plumbing.Capability.PluginInteraction (Waiting)
import Kyyn.Plumbing.Protocol.PluginHost (decodePluginHostCall)
import Kyyn.Porcelain.Protocol.PluginHost (decodeHostFrame, answerNetwork)
import Kyyn.Porcelain.Protocol.PluginBroker (conversationWithBody)
import Kyyn.Porcelain.Capability.PluginEvent
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Types.Plugin (FetchError(..))

runPluginEvent :: (GuestExecution :> es, HttpTransport :> es, SecretStore :> es, Waiting :> es, Failure :> es)
  => Eff (PluginEvent : es) a -> Eff es a
runPluginEvent = interpret $ \_ -> \case
  DispatchEvent entry config identity request -> do
    result <- conversationWithBody (decodeHostFrame decodePluginHostCall) entry
      (object ["config" .= config,"input" .= object ["waitIdentity" .= identity,"request" .= request]]) answerNetwork
    pure (either (\(FetchError message) -> Left [errorDiagnostic "flow.dispatch-failed" (Text.unpack message)]) Right result)
