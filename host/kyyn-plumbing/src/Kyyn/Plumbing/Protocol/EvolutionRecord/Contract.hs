module Kyyn.Plumbing.Protocol.EvolutionRecord.Contract
  ( snapshotShape, snapshotValue, restoreSnapshot, checkedSnapshotValue, restoreCheckedSnapshot ) where

import Data.Aeson (Value, object, (.=), withObject, (.:))
import Data.Aeson.Types (Parser)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Plumbing.Protocol.Description (descriptionShape, metadataShape, descriptionValue, parseDescription)

snapshotShape :: Shape
snapshotShape = Record [("types",descriptionShape),("metadata",metadataShape)]

snapshotValue :: RootContract -> Value
snapshotValue = checkedSnapshotValue . rootSchema

checkedSnapshotValue :: CheckedContract -> Value
checkedSnapshotValue schema = object ["types" .= descriptionValue (descriptionOf schema), "metadata" .= metadataOf schema]

restoreSnapshot :: Value -> Parser (Either [Diagnostic] RootContract)
restoreSnapshot value = fmap (>>= checkRootLayout) (restoreCheckedSnapshot value)

restoreCheckedSnapshot :: Value -> Parser (Either [Diagnostic] CheckedContract)
restoreCheckedSnapshot = withObject "Contract snapshot" $ \record -> do
  root <- record .: "types" >>= parseDescription
  metadata <- record .: "metadata"
  pure (checkContract root metadata)
