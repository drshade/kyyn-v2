module Kyyn.Porcelain.Protocol.PluginHost (answerNetwork, answerLogin, executeNetworkAcquisition, executeLogin) where

import Data.Aeson (Value, encode)
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Plumbing.Capability.Failure (Failure)
import qualified Kyyn.Plumbing.Capability.HttpTransport as Http
import qualified Kyyn.Plumbing.Capability.SecretStore as Secrets
import qualified Kyyn.Plumbing.Capability.PluginInteraction as Interaction
import Kyyn.Plumbing.Protocol.PluginHost
import Kyyn.Plumbing.Protocol.PluginMessages (decodeFrameWith, decodeCall, initialInput)
import Kyyn.Porcelain.Protocol.PluginBroker (protocolFailure, conversation, answerEvidence)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (CurrentEvidence)
import Kyyn.Types.Plugin (FetchError(..))

executeNetworkAcquisition :: (GuestExecution :> es, Http.HttpTransport :> es, Secrets.SecretStore :> es,
    Interaction.Waiting :> es, Failure :> es)
  => CompiledProgram -> Value -> Maybe CurrentEvidence -> Eff es (Either [Diagnostic] Value)
executeNetworkAcquisition program config prior = fmap (either
  (\(FetchError message) -> Left [errorDiagnostic "plugin.fetch-failed" message]) Right) $
  conversation (decodeFrameWith decode) program (initialInput config) (either (answerEvidence prior) answerNetwork)
  where
    decode "evidence" method args = Left <$> decodeCall "evidence" method args
    decode capability method args = Right <$> decodePluginHostCall capability method args

executeLogin :: (GuestExecution :> es, Http.HttpTransport :> es, Secrets.SecretStore :> es,
    Interaction.Waiting :> es, Interaction.LoginInteraction :> es, Failure :> es)
  => CompiledProgram -> Value -> Eff es (Either [Diagnostic] ())
executeLogin program config = do
  output <- conversation (decodeFrameWith decodePluginHostCall) program (Lazy.toStrict (encode config)) answerLogin
  case output of
    Left (FetchError message) -> pure (Left [errorDiagnostic "plugin.login-failed" message])
    Right value | value == unitResult -> pure (Right ())
                | otherwise -> protocolFailure "Invalid login result"

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
