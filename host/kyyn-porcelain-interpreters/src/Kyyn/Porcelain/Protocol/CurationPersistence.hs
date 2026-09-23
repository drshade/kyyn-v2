module Kyyn.Porcelain.Protocol.CurationPersistence
  ( encodeRegister, decodeRegister ) where

import Data.Aeson (object, (.=), (.:), toJSON, parseJSON)
import Data.Aeson.Types (parseEither, withObject)
import Data.ByteString (ByteString)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Contract (contractFingerprint, parseContractFingerprint)
import Kyyn.Domain.Curation
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Plugin (PackageIdentity(..), pluginName, pluginNameText)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)

registerShape :: Shape
registerShape = List (Record ([(name, Scalar TextScalar) |
  name <- ["recipe", "plugin", "instance", "producer", "contract"]] ++
  [("acknowledged", List (Record [("id", Scalar TextScalar), ("fingerprint", Scalar TextScalar)]))]))

encodeRegister :: DhallHandling :> es => CurationRegister -> Eff es (Either [Diagnostic] ByteString)
encodeRegister register = fmap (fmap Text.encodeUtf8) $ encodeValue registerShape $
  toJSON [object
    ["recipe" .= name, "plugin" .= pluginNameText plugin, "instance" .= instanceName,
     "producer" .= producer, "contract" .= contractFingerprint contract,
     "acknowledged" .= [object ["id" .= item, "fingerprint" .= token] |
       (EvidenceId item, EvidenceFingerprint token) <- items]] |
    (RecipeId name, ConnectorInstanceRef plugin instanceName,
      EvidenceProducer (PackageIdentity producer) contract, items) <- curationEntries register]

decodeRegister :: DhallHandling :> es => Maybe ByteString -> Eff es (Either [Diagnostic] CurationRegister)
decodeRegister Nothing = pure (Right emptyCurationRegister)
decodeRegister (Just bytes) = case Text.decodeUtf8' bytes of
  Left problem -> pure (failure (show problem))
  Right source -> do
    decoded <- decodeValue registerShape source
    pure $ decoded >>= \value ->
      either failure Right (parseEither parser value >>= curationRegister)
  where
    parser value = parseJSON value >>= traverse entry
    entry = withObject "curation entry" $ \fields -> do
      name <- fields .: "recipe" >>= either fail pure . recipeId
      plugin <- fields .: "plugin" >>= either fail pure . pluginName
      instanceName <- fields .: "instance"
      producer <- PackageIdentity <$> fields .: "producer"
      contract <- fields .: "contract" >>= either fail pure . parseContractFingerprint
      items <- fields .: "acknowledged" >>= traverse (withObject "acknowledged item" $ \item ->
        (,) <$> (EvidenceId <$> item .: "id") <*> (EvidenceFingerprint <$> item .: "fingerprint"))
      pure (name, ConnectorInstanceRef plugin instanceName, EvidenceProducer producer contract, items)
    failure = Left . pure . errorDiagnostic "curation.invalid-register"
