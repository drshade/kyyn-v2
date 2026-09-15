module Kyyn.Porcelain.Protocol.PluginBroker (executeAcquisition, executeCapturedRead) where

import Data.Aeson (Value, object, (.=), toJSON)
import Effectful (Eff, (:>), raise)
import Effectful.State.Static.Local (evalState, get, put)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Contract (CheckedContract, contractShape)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (CurrentEvidence(..), EvidenceId(..))
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Domain.Path (directoryScope, relativePath, relativeName)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeGuest)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import qualified Kyyn.Plumbing.Capability.FileAcquisition as Files
import Kyyn.Plumbing.Protocol.PluginMessages
import System.FilePath (takeDirectory, takeFileName)

executeAcquisition :: (GuestExecution :> es, Failure :> es, Files.FileAcquisition :> es)
  => CompiledProgram -> CheckedValue -> Maybe CurrentEvidence -> Eff es (Either [Diagnostic] Value)
executeAcquisition program config prior = conversation "plugin.fetch-failed" program config $ \call -> case call of
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
  -> Eff es (Either [Diagnostic] Value)
executeCapturedRead program arguments current result = do
  output <- conversation "plugin.read-failed" program arguments (answerEvidence (Just current))
  case output of
    Left diagnostics -> pure (Left diagnostics)
    Right value -> fmap (fmap (const value)) (encodeValue (contractShape result) value)

answerEvidence :: Failure :> es => Maybe CurrentEvidence -> PluginCall -> Eff es Value
answerEvidence prior call = case call of
  ListEvidence token -> do
    checkToken token
    pure (success (toJSON [key | (EvidenceId key,_) <- selected]))
  ReadEvidence token key -> do
    checkToken token
    pure (success (maybe (object ["tag" .= ("None" :: String)])
      (\value -> object ["tag" .= ("Some" :: String),"value" .= evidenceValue value]) (lookup key selected)))
  _ -> broken "Filesystem acquisition is unavailable in this invocation"
  where
    selected = maybe [] (\(CurrentEvidence _ values) -> values) prior
    checkToken token | token == "selected" = pure ()
                     | otherwise = broken "Unknown evidence snapshot handle"

conversation :: (GuestExecution :> es, Failure :> es)
  => String -> CompiledProgram -> CheckedValue -> (PluginCall -> Eff es Value) -> Eff es (Either [Diagnostic] Value)
conversation failureCode program arguments respond = do
  (output,ProcessExit status stderr) <- evalState (1 :: Integer) $ executeGuest program (initialInput arguments) $ \bytes -> do
    frame <- either broken pure (decodeFrame bytes)
    case frame of
      HostRequest identity call -> do
        expected <- get
        if identity /= expected then broken "Unexpected guest request ID" else put (expected + 1)
        value <- raise (respond call)
        pure (Just (encodeResponse identity value))
      Completed _ -> pure Nothing
  if status /= 0 then raiseFailure (RuntimeUnavailable (ProcessDiagnostic WaitForExit
    ("Plugin exited " ++ show status ++ ": " ++ show stderr))) else do
    frame <- either broken pure (decodeFrame output)
    case frame of
      Completed value -> case parseResult value of
        Left message -> broken message
        Right (Left message) -> pure (Left [errorDiagnostic failureCode message])
        Right (Right result) -> pure (Right result)
      _ -> broken "Guest did not complete"

broken :: Failure :> es => String -> Eff es a
broken message = raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput message))
