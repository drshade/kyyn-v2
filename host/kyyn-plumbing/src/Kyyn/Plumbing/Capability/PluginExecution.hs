module Kyyn.Plumbing.Capability.PluginExecution (executeAcquisition, executeCapturedRead) where

import Data.Aeson (Value, object, (.=), toJSON)
import Effectful (Eff, (:>), raise)
import Effectful.State.Static.Local (evalState, get, put)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Contract (CheckedContract, contractShape)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (EvidenceId(..), EvidenceSnapshotRef)
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Domain.Path (directoryScope, relativePath, relativeName)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeGuest)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import qualified Kyyn.Plumbing.Capability.EvidenceStore as Store
import qualified Kyyn.Plumbing.Capability.FileAcquisition as Files
import Kyyn.Plumbing.Protocol.PluginMessages
import System.FilePath (takeDirectory, takeFileName)

executeAcquisition :: (GuestExecution :> es, Failure :> es, Store.EvidenceStore :> es, Files.FileAcquisition :> es)
  => CompiledProgram -> CheckedValue -> CheckedContract -> Maybe EvidenceSnapshotRef
  -> Eff es (Either [Diagnostic] Value)
executeAcquisition program config payload prior = conversation program config $ \call -> case call of
  ListFiles directory recursive -> case directoryScope directory of
    Left message -> pure (failure message)
    Right scope -> either failure (success . toJSON . map relativeName) <$> Files.listSourceFiles scope recursive
  ReadText path -> case (,) <$> directoryScope (takeDirectory path) <*> relativePath (takeFileName path) of
    Left message -> pure (failure message)
    Right (scope,name) -> either failure (success . toJSON) <$> Files.readSourceText scope name
  other -> answerEvidence payload prior other

executeCapturedRead :: (GuestExecution :> es, Failure :> es, Store.EvidenceStore :> es, DhallHandling :> es)
  => CompiledProgram -> CheckedValue -> CheckedContract -> EvidenceSnapshotRef -> CheckedContract
  -> Eff es (Either [Diagnostic] Value)
executeCapturedRead program arguments payload snapshot result = do
  output <- conversation program arguments (answerEvidence payload (Just snapshot))
  case output of
    Left diagnostics -> pure (Left diagnostics)
    Right value -> fmap (fmap (const value)) (encodeValue (contractShape result) value)

answerEvidence :: (Store.EvidenceStore :> es, Failure :> es)
  => CheckedContract -> Maybe EvidenceSnapshotRef -> PluginCall -> Eff es Value
answerEvidence payload prior call = case call of
  ListEvidence token -> do
    checkToken token
    case prior of
      Nothing -> pure (success (toJSON ([] :: [String])))
      Just snapshot -> either (failure . show) (success . toJSON . map (\(EvidenceId key) -> key))
        <$> Store.listEvidenceIds snapshot payload
  ReadEvidence token key -> do
    checkToken token
    result <- maybe (pure (Right Nothing)) (\snapshot -> Store.readEvidence snapshot payload key) prior
    pure (either (failure . show) (success . maybe (object ["tag" .= ("None" :: String)])
      (\value -> object ["tag" .= ("Some" :: String),"value" .= evidenceValue value])) result)
  _ -> broken "Filesystem acquisition is unavailable in this invocation"
  where
    checkToken token | token == "selected" = pure ()
                     | otherwise = broken "Unknown evidence snapshot handle"

conversation :: (GuestExecution :> es, Failure :> es)
  => CompiledProgram -> CheckedValue -> (PluginCall -> Eff es Value) -> Eff es (Either [Diagnostic] Value)
conversation program arguments respond = do
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
        Right (Left message) -> pure (Left [errorDiagnostic "plugin.fetch-failed" message])
        Right (Right result) -> pure (Right result)
      _ -> broken "Guest did not complete"

broken :: Failure :> es => String -> Eff es a
broken message = raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput message))
