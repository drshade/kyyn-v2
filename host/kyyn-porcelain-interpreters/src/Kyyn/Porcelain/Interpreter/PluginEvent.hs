{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.PluginEvent (runPluginEvent) where

import Data.Aeson (Value, object, (.=), (.:), withObject)
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.Aeson.KeyMap as Keys
import Control.Monad (unless)
import Data.List (sort)
import Kyyn.Types.EventIdentity (EventIdentity(..))
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
  PollEvent entry config identity request cursor -> do
    let encodedCursor = maybe (object ["tag" .= ("None" :: Text.Text)])
          (\value -> object ["tag" .= ("Some" :: Text.Text),"value" .= value]) cursor
    result <- conversationWithBody (decodeHostFrame decodePluginHostCall) entry
      (object ["config" .= config,"input" .= object ["waitIdentity" .= identity,"request" .= request,"cursor" .= encodedCursor]]) answerNetwork
    pure $ case result of
      Left (FetchError message) -> Left [errorDiagnostic "flow.poll-failed" (Text.unpack message)]
      Right value -> either (Left . pure . errorDiagnostic "flow.poll-result") Right (parseEither parseBatch value)

parseBatch :: Value -> Parser ([(EventIdentity,Value)],Value)
parseBatch = withObject "event batch" $ \fields -> do
  unless (sort (Keys.keys fields) == ["arrivals","cursor"]) (fail "Expected arrivals and cursor")
  arrivals <- fields .: "arrivals" >>= traverse (withObject "event arrival" (\entry -> do
    unless (sort (Keys.keys entry) == ["identity","value"]) (fail "Expected identity and value")
    (,) <$> (EventIdentity <$> entry .: "identity") <*> entry .: "value"))
  (,) arrivals <$> fields .: "cursor"
