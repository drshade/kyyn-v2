module Kyyn.Plumbing.Capability.SchemaInspection.Metadata
  ( metadataAdapter, decodeMetadata, evaluateMetadata ) where

import Data.Aeson (eitherDecodeStrict)
import qualified Data.ByteString as Bytes
import Effectful (Eff, (:>))
import Kyyn.Types.SchemaMetadata
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution
import Kyyn.Plumbing.Capability.GuestCompilation.Types (bindingModule)
import Kyyn.Plumbing.Capability.ProcessExecution

metadataAdapter :: String -> Either String String
metadataAdapter selected = do
  moduleName <- bindingModule selected
  pure (unlines ["module KyynMetadataEntry where", "import qualified " ++ moduleName,
      "import Kyyn.Runtime.SchemaMetadata (encodeMetadata)",
      "import Kyyn.Runtime.Transport (withTransport, writeJson)",
      "main :: IO ()", "main = withTransport $ \\transport -> either fail (writeJson transport) (encodeMetadata " ++ selected ++ ")"])

decodeMetadata :: Bytes.ByteString -> Either String SchemaMetadata
decodeMetadata = eitherDecodeStrict

evaluateMetadata
  :: (GuestCompilation :> es, GuestExecution :> es, Failure :> es)
  => GuestSources -> Eff es (Either [Diagnostic] SchemaMetadata)
evaluateMetadata sources = do
  compiled <- compileGuest sources
  case compiled of
    Left diagnostics -> pure (Left diagnostics)
    Right entry -> do
      (output, ProcessExit status diagnostics) <- executeCompiled entry Bytes.empty
      if status /= 0
        then raiseFailure (RuntimeUnavailable (ProcessDiagnostic WaitForExit
          ("metadata entry exited " ++ show status ++ ": " ++ show diagnostics)))
        else case decodeMetadata output of
          Left message -> raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput
            ("invalid metadata response: " ++ message)))
          Right value -> pure (Right value)
