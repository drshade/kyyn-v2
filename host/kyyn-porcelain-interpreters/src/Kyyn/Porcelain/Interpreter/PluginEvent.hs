{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.PluginEvent (runPluginEvent) where

import Data.Aeson (object, (.=))
import Kyyn.Plumbing.Capability.Deadline (Deadline, withinMicroseconds)
import Data.Aeson.Types (parseEither)
import Kyyn.Porcelain.Protocol.PluginEvent (parseEventBatch)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.HttpTransport (HttpTransport)
import Kyyn.Plumbing.Capability.SecretStore (SecretStore)
import Kyyn.Plumbing.Capability.PluginInteraction (Waiting)
import Kyyn.Plumbing.Protocol.PluginHost (decodePluginHostCall)
import Kyyn.Porcelain.Protocol.PluginHost (adapterDeadlineMicroseconds, decodeHostFrame, answerNetwork)
import Kyyn.Porcelain.Protocol.PluginBroker (conversationWithBody)
import Kyyn.Porcelain.Capability.PluginEvent
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Types.Plugin (FetchError(..))

runPluginEvent :: (GuestExecution :> es, HttpTransport :> es, SecretStore :> es, Waiting :> es, Failure :> es, Deadline :> es)
  => Eff (PluginEvent : es) a -> Eff es a
runPluginEvent = interpret $ \_ -> \case
  DispatchEvent entry config identity request -> invoke "flow.dispatch-failed" entry
    (object ["config" .= config,"input" .= object ["waitIdentity" .= identity,"request" .= request]])
  PollEvent entry config identity request cursor -> do
    let encodedCursor = maybe (object ["tag" .= ("None" :: Text.Text)])
          (\value -> object ["tag" .= ("Some" :: Text.Text),"value" .= value]) cursor
    result <- invoke "flow.poll-failed" entry
      (object ["config" .= config,"input" .= object ["waitIdentity" .= identity,"request" .= request,"cursor" .= encodedCursor]])
    pure $ result >>= either (Left . pure . errorDiagnostic "flow.poll-result") Right . parseEither parseEventBatch
  where
    invoke failureCode entry input = do
      result <- withinMicroseconds adapterDeadlineMicroseconds
        (conversationWithBody (decodeHostFrame decodePluginHostCall) entry input answerNetwork)
      pure $ case result of
        Nothing -> Left [errorDiagnostic "flow.adapter-timeout" "Event adapter exceeded its 60-second deadline."]
        Just (Left (FetchError message)) -> Left [errorDiagnostic failureCode (Text.unpack message)]
        Just (Right value) -> Right value
