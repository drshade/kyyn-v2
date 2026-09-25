module Kyyn.Porcelain.Protocol.PluginBroker (executeAcquisition, executeCapturedRead, conversation, protocolFailure) where

import Data.Aeson (Value, object, (.=), toJSON)
import Data.ByteString (ByteString)
import Effectful (Eff, (:>), raise)
import Effectful.State.Static.Local (evalState, get, put)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Contract (CheckedContract, contractShape)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (CurrentEvidence(..), EvidenceId(..))
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Domain.Path (directoryScope, relativePath, relativeName)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeGuest)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import qualified Kyyn.Plumbing.Capability.FileAcquisition as Files
import Kyyn.Plumbing.Protocol.PluginMessages
import System.FilePath (takeDirectory, takeFileName)

executeAcquisition :: (GuestExecution :> es, Failure :> es, Files.FileAcquisition :> es)
  => CompiledProgram -> Value -> Maybe CurrentEvidence -> Eff es (Either [Diagnostic] Value)
executeAcquisition program config prior = fmap (either (\(FetchError message) -> Left [errorDiagnostic "plugin.fetch-failed" message]) Right) $
  conversation decodeFrame program (initialInput config) $ \call -> case call of
  ListFiles directory recursive -> case directoryScope directory of
    Left message -> pure (failure message)
    Right scope -> either failure (success . toJSON . map relativeName) <$> Files.listSourceFiles scope recursive
  ReadText path -> case (,) <$> directoryScope (takeDirectory path) <*> relativePath (takeFileName path) of
    Left message -> pure (failure message)
    Right (scope,name) -> either failure (\(Files.CapturedText contents (Files.EvidenceFingerprint fingerprint)) ->
      success (object ["contents" .= contents,"fingerprint" .= fingerprint])) <$> Files.readSourceText scope name
  other -> answerEvidence prior other

executeCapturedRead :: (GuestExecution :> es, Failure :> es, DhallHandling :> es)
  => CompiledProgram -> CheckedValue -> CurrentEvidence -> CheckedContract
  -> Eff es (Either [Diagnostic] (Either FetchError Value))
executeCapturedRead program (CheckedValue _ arguments) current result = do
  output <- conversation decodeFrame program (initialInput arguments) (answerEvidence (Just current))
  case output of
    Left problem -> pure (Right (Left problem))
    Right value -> fmap (fmap (const (Right value))) (encodeValue (contractShape result) value)

answerEvidence :: Failure :> es => Maybe CurrentEvidence -> PluginCall -> Eff es Value
answerEvidence prior call = case call of
  ListEvidence token -> do
    checkToken token
    pure (success (toJSON [key | (EvidenceId key,_) <- selected]))
  ReadEvidence token key -> do
    checkToken token
    pure (success (maybe (object ["tag" .= ("None" :: String)])
      (\value -> object ["tag" .= ("Some" :: String),"value" .= evidenceValue value]) (lookup key selected)))
  _ -> protocolFailure "Filesystem acquisition is unavailable in this invocation"
  where
    selected = maybe [] (\(CurrentEvidence _ values) -> values) prior
    checkToken token | token == "selected" = pure ()
                     | otherwise = protocolFailure "Unknown evidence snapshot handle"

conversation :: (GuestExecution :> es, Failure :> es)
  => (ByteString -> Either String (PluginFrame call)) -> CompiledProgram -> ByteString
  -> (call -> Eff es Value) -> Eff es (Either FetchError Value)
conversation decode program arguments respond = do
  (output,ProcessExit status stderr) <- evalState (1 :: Integer) $ executeGuest program arguments $ \bytes -> do
    frame <- either protocolFailure pure (decode bytes)
    case frame of
      HostRequest identity call -> do
        expected <- get
        if identity /= expected then protocolFailure "Unexpected guest request ID" else put (expected + 1)
        value <- raise (respond call)
        pure (Just (encodeResponse identity value))
      Completed _ -> pure Nothing
  if status /= 0 then raiseFailure (RuntimeUnavailable (ProcessDiagnostic WaitForExit
    ("Plugin exited " ++ show status ++ ": " ++ show stderr))) else do
    frame <- either protocolFailure pure (decode output)
    case frame of
      Completed value -> case parseResult value of
        Left message -> protocolFailure message
        Right (Left message) -> pure (Left (FetchError message))
        Right (Right result) -> pure (Right result)
      _ -> protocolFailure "Guest did not complete"

protocolFailure :: Failure :> es => String -> Eff es a
protocolFailure message = raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput message))
