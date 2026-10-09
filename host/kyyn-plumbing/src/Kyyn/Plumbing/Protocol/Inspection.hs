module Kyyn.Plumbing.Protocol.Inspection
  ( encodeInspection, decodeInspection, encodePluginSignature, decodePluginSignature
  , encodeRecipeExports, decodeRecipeExports ) where

import Data.Aeson (object, (.=), (.:), withObject)
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Path (RelativePath, relativeName, relativePath)
import Kyyn.Domain.Plugin (PluginSignature(..))
import Kyyn.Domain.Recipe (RecipeSignature(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Protocol.DataType (dataTypeShape, dataTypeValue, parseDataType)

inspectionShape :: Shape
inspectionShape = Record [("type",dataTypeShape),("closure",List (Scalar TextScalar))]

recipeExportsShape :: Shape
recipeExportsShape = Record
  [("exports",List (Record [("name",Scalar TextScalar),("root",dataTypeShape),
    ("input",dataTypeShape),("state",dataTypeShape)])),("closure",List (Scalar TextScalar))]

encodeRecipeExports :: DhallHandling :> es => ([(String,RecipeSignature)],[RelativePath])
  -> Eff es (Either [Diagnostic] ByteString)
encodeRecipeExports (signatures,closure) = fmap (fmap Text.encodeUtf8) $ encodeValue recipeExportsShape
  (object ["exports" .= [object ["name" .= name,"root" .= dataTypeValue root,
    "input" .= dataTypeValue input,"state" .= dataTypeValue state]
    | (name,RecipeSignature root input state) <- signatures],"closure" .= map relativeName closure])

decodeRecipeExports :: DhallHandling :> es => ByteString
  -> Eff es (Either [Diagnostic] ([(String,RecipeSignature)],[RelativePath]))
decodeRecipeExports bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (bad (show problem))
  Right source -> do
    decoded <- decodeValue recipeExportsShape source
    pure (decoded >>= either bad Right . parseEither (withObject "recipe exports" $ \record ->
      (,) <$> (record .: "exports" >>= traverse (withObject "recipe export" $ \entry ->
        (,) <$> entry .: "name" <*> (RecipeSignature
          <$> (entry .: "root" >>= parseDataType)
          <*> (entry .: "input" >>= parseDataType)
          <*> (entry .: "state" >>= parseDataType))))
        <*> (record .: "closure" >>= traverse (either fail pure . relativePath))))
  where bad = Left . pure . errorDiagnostic "inspection.cache-invalid"

signatureShape :: Shape
signatureShape = Record [("kind",Scalar TextScalar),("types",List dataTypeShape),("closure",List (Scalar TextScalar))]

encodePluginSignature :: DhallHandling :> es => (PluginSignature,[RelativePath]) -> Eff es (Either [Diagnostic] ByteString)
encodePluginSignature (signature,closure) = fmap (fmap Text.encodeUtf8) $ encodeValue signatureShape
  (object ["kind" .= kind,"types" .= map dataTypeValue types,"closure" .= map relativeName closure])
  where
    (kind,types) = case signature of
      FetchSignature config options payload -> ("fetch" :: String,[config,payload] ++ maybe [] pure options)
      StatefulFetchSignature config options payload position -> ("stateful-fetch",[config,payload,position] ++ maybe [] pure options)
      ReadSignature input payload result -> ("read",[input,payload,result])
      SinkSignature config options input result -> ("sink",[config,options,input,result])

decodePluginSignature :: DhallHandling :> es => ByteString -> Eff es (Either [Diagnostic] (PluginSignature,[RelativePath]))
decodePluginSignature bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (bad (show problem))
  Right source -> do
    decoded <- decodeValue signatureShape source
    pure (decoded >>= either bad Right . parseEither (withObject "plugin signature" $ \record -> do
      kind <- record .: "kind"
      types <- record .: "types" >>= traverse parseDataType
      signature <- case (kind :: String,types) of
        ("fetch",[config,payload]) -> pure (FetchSignature config Nothing payload)
        ("fetch",[config,payload,options]) -> pure (FetchSignature config (Just options) payload)
        ("stateful-fetch",[config,payload,position]) -> pure (StatefulFetchSignature config Nothing payload position)
        ("stateful-fetch",[config,payload,position,options]) -> pure (StatefulFetchSignature config (Just options) payload position)
        ("read",[input,payload,result]) -> pure (ReadSignature input payload result)
        ("sink",[config,options,input,result]) -> pure (SinkSignature config options input result)
        _ -> fail "Invalid plugin signature cache"
      closure <- record .: "closure" >>= traverse (either fail pure . relativePath)
      pure (signature,closure)))
  where bad = Left . pure . errorDiagnostic "inspection.cache-invalid"

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
