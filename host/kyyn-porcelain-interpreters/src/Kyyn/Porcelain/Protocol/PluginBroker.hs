module Kyyn.Porcelain.Protocol.PluginBroker (answerAcquisition, executeCapturedRead, conversation, conversationWithBody, answerEvidence, protocolFailure) where

import Data.Aeson (Value, object, (.=), toJSON)
import Data.ByteString (ByteString)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>), raise)
import Effectful.State.Static.Local (evalState, get, put)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Contract (CheckedContract, contractShape)
import Kyyn.Domain.Diagnostic (Diagnostic)
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
import Kyyn.Plumbing.Protocol.Frame (Frame(..), jsonFrame)
import System.FilePath (takeDirectory, takeFileName)

answerAcquisition :: (Failure :> es, Files.FileAcquisition :> es)
  => Maybe CurrentEvidence -> PluginCall -> Eff es Value
answerAcquisition prior call = case call of
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
    selected = maybe [] (\(CurrentEvidence _ values _) -> values) prior
    checkToken token | token == "selected" = pure ()
                     | otherwise = protocolFailure "Unknown evidence snapshot handle"

conversation :: (GuestExecution :> es, Failure :> es)
  => (ByteString -> Either String (PluginFrame call)) -> CompiledProgram -> ByteString
  -> (call -> Eff es Value) -> Eff es (Either FetchError Value)
conversation decode program arguments respond = do
  conversationWithBody (\(Frame bytes body) -> if Bytes.null body then decode bytes else Left "Unexpected raw body")
    program arguments (\call -> (,) <$> respond call <*> pure Bytes.empty)

conversationWithBody :: (GuestExecution :> es, Failure :> es)
  => (Frame -> Either String (PluginFrame call)) -> CompiledProgram -> ByteString
  -> (call -> Eff es (Value,ByteString)) -> Eff es (Either FetchError Value)
conversationWithBody decode program arguments respond = do
  (output,ProcessExit status stderr) <- evalState (1 :: Integer) $ executeGuest program (jsonFrame arguments) $ \bytes -> do
    frame <- either protocolFailure pure (decode bytes)
    case frame of
      HostRequest identity call -> do
        expected <- get
        if identity /= expected then protocolFailure "Unexpected guest request ID" else put (expected + 1)
        (value,body) <- raise (respond call)
        pure (Just (Frame (encodeResponse identity value) body))
      Completed _ -> pure Nothing
  if status /= 0 then raiseFailure (RuntimeUnavailable (ProcessDiagnostic WaitForExit
    ("Plugin exited " ++ show status ++ ": " ++ diagnostics stderr))) else do
    frame <- either protocolFailure pure (decode output)
    case frame of
      Completed value -> case parseResult value of
        Left message -> protocolFailure message
        Right (Left message) -> pure (Left (FetchError (Text.pack message)))
        Right (Right result) -> pure (Right result)
      _ -> protocolFailure "Guest did not complete"

diagnostics :: ByteString -> String
diagnostics bytes = case Text.decodeUtf8' bytes of
  Left _ -> "Non-UTF-8 guest diagnostics"
  Right message -> unlines (takeWhile (\line -> line /= "CallStack (from HasCallStack):" &&
    line /= "HasCallStack backtrace:") (lines (Text.unpack message)))

protocolFailure :: Failure :> es => String -> Eff es a
protocolFailure message = raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput message))
