module Kyyn.Plumbing.Protocol.Plugin (decodeManifest, encodeOrigin, decodeOrigin) where

import Data.Aeson (Value, object, (.=), (.:))
import Data.Aeson.Types (Parser, parseEither, withObject)
import Data.ByteString (ByteString)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Git (TreePath(..))
import Kyyn.Domain.Path (directoryScope, scopePath, relativePath, relativeName)
import Kyyn.Domain.Plugin
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, decodeValue, encodeValue)

decodeManifest :: DhallHandling :> es => ByteString -> Eff es (Either [Diagnostic] PluginManifest)
decodeManifest = decode "plugin.manifest-invalid" manifestShape $ withObject "plugin manifest" $ \fields -> do
  name <- fields .: "name"
  entry <- fields .: "entryModule"
  either fail pure (pluginManifest name entry)

encodeOrigin :: DhallHandling :> es => PluginSource -> Eff es (Either [Diagnostic] ByteString)
encodeOrigin source = fmap (fmap Text.encodeUtf8) (encodeValue originShape (object ["source" .= selected, "path" .= pathValue path]))
  where
    (selected,path) = case source of
      LocalPackage scope p -> (tagged "Local" (scopePath scope),p)
      GitPackage url p -> (tagged "Git" (gitUrlText url),p)
    tagged :: String -> String -> Value
    tagged tag value = object ["tag" .= tag, "value" .= value]
    pathValue WholeTree = object ["tag" .= ("None" :: String)]
    pathValue (Subtree p) = tagged "Some" (relativeName p)

decodeOrigin :: DhallHandling :> es => ByteString -> Eff es (Either [Diagnostic] PluginSource)
decodeOrigin = decode "plugin.origin-invalid" originShape $ withObject "plugin origin" $ \fields -> do
  path <- fields .: "path" >>= withObject "package path" (\p -> do
    tag <- p .: "tag"
    case tag :: String of
      "None" -> pure WholeTree
      "Some" -> p .: "value" >>= either fail (pure . Subtree) . relativePath
      _ -> fail "Unknown optional path")
  fields .: "source" >>= withObject "source" (\s -> do
    tag <- s .: "tag"
    value <- s .: "value"
    case tag :: String of
      "Local" -> either fail (\scope -> pure (LocalPackage scope path)) (directoryScope value)
      "Git" -> either fail (\url -> pure (GitPackage url path)) (gitUrl value)
      _ -> fail "Unknown origin source")

manifestShape, originShape :: Shape
manifestShape = Record [("name",text), ("entryModule",text)]
originShape = Record [("source",Union [("Local",Just text),("Git",Just text)]), ("path",Optional text)]

text :: Shape
text = Scalar TextScalar

decode :: DhallHandling :> es => String -> Shape -> (Value -> Parser a) -> ByteString -> Eff es (Either [Diagnostic] a)
decode code shape parser bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (bad (show problem))
  Right source -> do
    decoded <- decodeValue shape source
    pure $ case decoded of
      Left diagnostics -> bad (show diagnostics)
      Right value -> either bad Right (parseEither parser value)
  where bad = Left . pure . errorDiagnostic code
