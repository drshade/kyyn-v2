module Kyyn.Plumbing.Protocol.Plugin (decodeManifest, encodeOrigin, decodeOrigin) where

import Data.Aeson (Value, object, (.=), (.:))
import Data.Aeson.Types (Parser, parseEither, withObject)
import Data.ByteString (ByteString)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic(..), errorDiagnostic)
import Kyyn.Domain.Git (TreePath(..), gitRevision, revisionName, gitUrl, gitUrlText)
import Kyyn.Domain.Path (directoryScope, scopePath, relativePath, relativeName)
import Kyyn.Domain.Plugin
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, decodeValue, encodeValue)

decodeManifest :: DhallHandling :> es => ByteString -> Eff es (Either [Diagnostic] PluginManifest)
decodeManifest = decode "plugin.manifest-invalid" manifestShape $ withObject "plugin manifest" $ \fields -> do
  name <- fields .: "name"
  entry <- fields .: "entryModule"
  either fail pure (pluginManifest name entry)

encodeOrigin :: DhallHandling :> es => PluginOrigin -> Eff es (Either [Diagnostic] ByteString)
encodeOrigin (PluginOrigin repository path revision) = fmap (fmap Text.encodeUtf8) (encodeValue originShape
  (object ["repository" .= selected, "path" .= pathValue path, "revision" .= revisionName revision]))
  where
    selected = case repository of
      LocalRepository scope -> tagged "Local" (scopePath scope)
      RemoteRepository url -> tagged "Git" (gitUrlText url)
    tagged :: String -> String -> Value
    tagged tag value = object ["tag" .= tag, "value" .= value]
    pathValue WholeTree = object ["tag" .= ("None" :: String)]
    pathValue (Subtree p) = tagged "Some" (relativeName p)

decodeOrigin :: DhallHandling :> es => ByteString -> Eff es (Either [Diagnostic] PluginOrigin)
decodeOrigin = decode "plugin.origin-invalid" originShape $ withObject "plugin origin" $ \fields -> do
  path <- fields .: "path" >>= withObject "package path" (\p -> do
    tag <- p .: "tag"
    case tag :: String of
      "None" -> pure WholeTree
      "Some" -> p .: "value" >>= either fail (pure . Subtree) . relativePath
      _ -> fail "Unknown optional path")
  revision <- fields .: "revision" >>= either fail pure . gitRevision
  repository <- fields .: "repository" >>= withObject "repository" (\s -> do
    tag <- s .: "tag"
    value <- s .: "value"
    case tag :: String of
      "Local" -> either fail (pure . LocalRepository) (directoryScope value)
      "Git" -> either fail (pure . RemoteRepository) (gitUrl value)
      _ -> fail "Unknown origin source")
  pure (PluginOrigin repository path revision)

manifestShape, originShape :: Shape
manifestShape = Record [("name",text), ("entryModule",text)]
originShape = Record [("repository",Union [("Local",Just text),("Git",Just text)]), ("path",Optional text), ("revision",text)]

text :: Shape
text = Scalar TextScalar

decode :: DhallHandling :> es => String -> Shape -> (Value -> Parser a) -> ByteString -> Eff es (Either [Diagnostic] a)
decode code shape parser bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (bad (show problem))
  Right source -> do
    decoded <- decodeValue shape source
    pure $ case decoded of
      Left diagnostics -> Left [Diagnostic severity code message location | Diagnostic severity _ message location <- diagnostics]
      Right value -> either bad Right (parseEither parser value)
  where bad = Left . pure . errorDiagnostic code
