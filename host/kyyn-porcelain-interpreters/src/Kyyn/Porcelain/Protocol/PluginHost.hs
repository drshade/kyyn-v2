module Kyyn.Porcelain.Protocol.PluginHost (answerNetwork, answerLogin, executeAcquisition, executeLogin) where

import Data.Aeson (Value, encode)
import Data.Aeson.Types (Parser)
import qualified Data.ByteString as Bytes
import Control.Monad (unless)
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.FileAcquisition (FileAcquisition)
import qualified Kyyn.Plumbing.Capability.HttpTransport as Http
import qualified Kyyn.Plumbing.Capability.SecretStore as Secrets
import qualified Kyyn.Plumbing.Capability.PluginInteraction as Interaction
import Kyyn.Plumbing.Protocol.PluginHost
import Kyyn.Plumbing.Protocol.PluginMessages (PluginFrame(..), decodeFrameWith, decodeCall, initialInput)
import Kyyn.Plumbing.Protocol.Frame (Frame(..))
import Kyyn.Porcelain.Protocol.PluginBroker (protocolFailure, conversationWithBody, answerAcquisition)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (CurrentEvidence, ConnectorInstanceRef)
import qualified Kyyn.Plumbing.Capability.BlobStorage as Blobs
import Kyyn.Plumbing.Protocol.Blob (decodeDownload, downloadResult)
import Kyyn.Types.Plugin (FetchError(..))

executeAcquisition :: (Blobs.BlobStorage :> es, GuestExecution :> es, FileAcquisition :> es, Http.HttpTransport :> es, Secrets.SecretStore :> es,
    Interaction.Waiting :> es, Failure :> es)
  => ConnectorInstanceRef -> CompiledProgram -> Value -> Maybe CurrentEvidence -> Eff es (Either [Diagnostic] Value)
executeAcquisition instanceRef program config prior = fmap (either
  (\(FetchError message) -> Left [errorDiagnostic "plugin.fetch-failed" (Text.unpack message)]) Right) $
  conversationWithBody (decodeHostFrame decode) program (initialInput config)
    (either (fmap (\result -> (downloadResult result,Bytes.empty)) . Blobs.storeBlobAt instanceRef)
      (either (fmap (,Bytes.empty) . answerAcquisition prior) answerNetwork))
  where
    decode body "blobs" "store" args = Left <$> decodeDownload body args
    decode _ "evidence" method args = Right . Left <$> decodeCall "evidence" method args
    decode _ "files" method args = Right . Left <$> decodeCall "files" method args
    decode body capability method args = Right . Right <$> decodePluginHostCall body capability method args

executeLogin :: (GuestExecution :> es, Http.HttpTransport :> es, Secrets.SecretStore :> es,
    Interaction.Waiting :> es, Interaction.LoginInteraction :> es, Failure :> es)
  => CompiledProgram -> Value -> Eff es (Either [Diagnostic] ())
executeLogin program config = do
  output <- conversationWithBody (decodeHostFrame decodePluginHostCall) program (Lazy.toStrict (encode config)) answerLogin
  case output of
    Left (FetchError message) -> pure (Left [errorDiagnostic "plugin.login-failed" (Text.unpack message)])
    Right value | value == unitResult -> pure (Right ())
                | otherwise -> protocolFailure "Invalid login result"

answerNetwork :: (Http.HttpTransport :> es, Secrets.SecretStore :> es, Interaction.Waiting :> es, Failure :> es)
  => PluginHostCall -> Eff es (Value,Bytes.ByteString)
answerNetwork call = case call of
  HttpCall request -> httpResult <$> Http.sendHttp request
  GetSecret key -> (,Bytes.empty) . secretResult . fmap Text.unpack <$> Secrets.readSecret key
  PutSecret key value -> Secrets.writeSecret key (Text.pack value) >> pure (unitResult,Bytes.empty)
  WaitSeconds seconds -> Interaction.waitSeconds seconds >> pure (unitResult,Bytes.empty)
  DisplayInstructions _ -> protocolFailure "Interactive login is unavailable during acquisition"

answerLogin :: (Http.HttpTransport :> es, Secrets.SecretStore :> es, Interaction.Waiting :> es,
    Interaction.LoginInteraction :> es, Failure :> es) => PluginHostCall -> Eff es (Value,Bytes.ByteString)
answerLogin (DisplayInstructions message) = Interaction.displayInstructions message >> pure (unitResult,Bytes.empty)
answerLogin call = answerNetwork call

decodeHostFrame :: (Bytes.ByteString -> String -> String -> Value -> Parser call) -> Frame -> Either String (PluginFrame call)
decodeHostFrame decode (Frame metadata body) = do
  frame <- decodeFrameWith (\capability method arguments -> do
    unless (Bytes.null body || (capability == "http" && method == "send") || (capability == "blobs" && method == "store")) (fail "Unexpected raw body")
    decode body capability method arguments) metadata
  case frame of
    Completed _ | not (Bytes.null body) -> Left "Raw body accompanies terminal result"
    _ -> Right frame
