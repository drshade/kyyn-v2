module Kyyn.Plumbing.Protocol.Inspection (encodeInspection, decodeInspection) where

import Data.Aeson (object, (.=), (.:), withObject)
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Path (RelativePath, relativeName, relativePath)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Protocol.DataType (dataTypeShape, dataTypeValue, parseDataType)

inspectionShape :: Shape
inspectionShape = Record [("type",dataTypeShape),("closure",List (Scalar TextScalar))]

encodeInspection :: DhallHandling :> es => (DataType,[RelativePath]) -> Eff es (Either [Diagnostic] ByteString)
encodeInspection (structure,closure) = fmap (fmap Text.encodeUtf8) $ encodeValue inspectionShape
  (object ["type" .= dataTypeValue structure, "closure" .= map relativeName closure])

decodeInspection :: DhallHandling :> es => ByteString -> Eff es (Either [Diagnostic] (DataType,[RelativePath]))
decodeInspection bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (bad (show problem))
  Right source -> do
    decoded <- decodeValue inspectionShape source
    pure (decoded >>= either bad Right . parseEither (withObject "inspection" $ \record ->
      (,) <$> (record .: "type" >>= parseDataType)
          <*> (record .: "closure" >>= traverse (either fail pure . relativePath))))
  where bad = Left . pure . errorDiagnostic "inspection.cache-invalid"
