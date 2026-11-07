module Kyyn.Plumbing.Protocol.EvolutionRecord.Contract
  ( snapshotShape, snapshotValue, restoreSnapshot, checkedSnapshotValue, restoreCheckedSnapshot ) where

import Data.Aeson (Value, object, (.=), withObject, (.:))
import Data.Aeson.Types (Parser)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Plumbing.Protocol.Description (descriptionShape, metadataShape, descriptionValue, parseDescription)

snapshotShape :: Shape
snapshotShape = Record [("fingerprint",Scalar TextScalar),("types",descriptionShape),("metadata",metadataShape)]

snapshotValue :: RootContract -> Value
snapshotValue = checkedSnapshotValue . rootSchema

checkedSnapshotValue :: CheckedContract -> Value
checkedSnapshotValue schema = object ["fingerprint" .= contractFingerprint (contractId schema),
  "types" .= descriptionValue (descriptionOf schema), "metadata" .= metadataOf schema]

restoreSnapshot :: Value -> Parser (Either [Diagnostic] RootContract)
restoreSnapshot value = fmap (>>= checkRootLayout) (restoreCheckedSnapshot value)

restoreCheckedSnapshot :: Value -> Parser (Either [Diagnostic] CheckedContract)
restoreCheckedSnapshot = withObject "Contract snapshot" $ \record -> do
  fingerprint <- record .: "fingerprint"
  root <- record .: "types" >>= parseDescription
  metadata <- record .: "metadata"
  pure $ case checkContract root metadata of
    Right contract | contractFingerprint (contractId contract) == fingerprint -> Right contract
    _ -> Left [errorDiagnostic "schema.stored-contract" "Stored contract cannot be reconstructed with its fingerprint by this kernel"]
