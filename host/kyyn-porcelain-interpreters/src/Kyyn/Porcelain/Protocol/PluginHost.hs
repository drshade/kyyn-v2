module Kyyn.Porcelain.Protocol.PluginHost (answerNetwork, answerLogin) where

import Data.Aeson (Value)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Plumbing.Capability.Failure (Failure)
import qualified Kyyn.Plumbing.Capability.HttpTransport as Http
import qualified Kyyn.Plumbing.Capability.SecretStore as Secrets
import qualified Kyyn.Plumbing.Capability.PluginInteraction as Interaction
import Kyyn.Plumbing.Protocol.PluginHost
import Kyyn.Porcelain.Protocol.PluginBroker (protocolFailure)

answerNetwork :: (Http.HttpTransport :> es, Secrets.SecretStore :> es, Interaction.Waiting :> es, Failure :> es)
  => PluginHostCall -> Eff es Value
answerNetwork call = case call of
  HttpCall request -> httpResult <$> Http.sendHttp request
  GetSecret key -> secretResult . fmap Text.unpack <$> Secrets.readSecret key
  PutSecret key value -> Secrets.writeSecret key (Text.pack value) >> pure unitResult
  WaitSeconds seconds -> Interaction.waitSeconds seconds >> pure unitResult
  DisplayInstructions _ -> protocolFailure "Interactive login is unavailable during acquisition"

answerLogin :: (Http.HttpTransport :> es, Secrets.SecretStore :> es, Interaction.Waiting :> es,
    Interaction.LoginInteraction :> es, Failure :> es) => PluginHostCall -> Eff es Value
answerLogin (DisplayInstructions message) = Interaction.displayInstructions message >> pure unitResult
answerLogin call = answerNetwork call
