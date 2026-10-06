module Kyyn.Plumbing.Protocol.PluginRegistration (registrationSources, decodeConnectors, registrationFailure) where

import Control.Monad (unless, forM)
import Data.Aeson (eitherDecodeStrict, withArray, withObject, (.:))
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.Foldable (toList)
import Data.List (nub, sort, isInfixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Domain.Plugin (ConnectorDeclaration(..), CapturedMethodDeclaration(..), connectorTypeName, methodName)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources, bindingModule)
import Kyyn.Types.Plugin (SourceConnector(SourceConnector), CapturedMethod(CapturedMethod))

registrationFailure :: Bytes.ByteString -> String
registrationFailure bytes = "Could not evaluate connector registration.\n" ++ message ++ hint
  where
    message = case Text.decodeUtf8' bytes of
      Left _ -> "Guest returned non-UTF-8 diagnostics.\n"
      Right value -> unlines (takeWhile (\line -> line /= "CallStack (from HasCallStack):" &&
        line /= "HasCallStack backtrace:") (lines (Text.unpack value)))
    hint | "KyynPluginBindings" `isInfixOf` message = "Import Kyyn.Plugin / Kyyn.Plugin.Host instead of KyynPluginBindings; use Acquisition Payload and CapturedRead Payload in signatures."
         | "Missing field" `isInfixOf` message =
             "Initialize every SourceConnector field, including login (Nothing when unused)."
         | otherwise = "Check the plugin's connectors declaration."

registrationSources :: String -> [(RelativePath,Bytes.ByteString)] -> Either String GuestSources
registrationSources entryModule sources = do
  _ <- bindingModule (entryModule ++ ".connectors")
  path <- relativePath "KyynPluginRegistrationEntry.hs"
  let adapter = unlines ["module KyynPluginRegistrationEntry where","import qualified " ++ entryModule,
        "import Kyyn.Runtime.PluginRegistration (encodeConnectors)",
        "import Kyyn.Runtime.Transport (withTransport, writeJson)","main :: IO ()",
        "main = withTransport $ \\transport -> either fail (writeJson transport) (encodeConnectors " ++ entryModule ++ ".connectors)"]
  guestSources path (sources ++ [(path, Text.encodeUtf8 (Text.pack adapter))])

decodeConnectors :: Bytes.ByteString -> Either String [ConnectorDeclaration]
decodeConnectors bytes = do
  declarations <- eitherDecodeStrict bytes >>= parseEither (withArray "connectors" (traverse connector . toList))
  let names = [name | SourceConnector name _ _ _ _ <- declarations]
  unless (length names == length (nub names)) (Left "Connector type names must be unique within a plugin")
  forM declarations $ \(SourceConnector name fetch validate methods login) -> do
    checkedName <- connectorTypeName name
    _ <- either (Left . ((name ++ ": fetch: ") ++)) Right (bindingModule fetch)
    _ <- either (Left . ((name ++ ": validateConfig: ") ++)) Right (bindingModule validate)
    _ <- traverse (either (Left . ((name ++ ": login: ") ++)) Right . bindingModule) login
    let methodNames = [n | CapturedMethod n _ _ <- methods]
    unless (length methodNames == length (nub methodNames)) (Left (name ++ ": Method names must be unique"))
    checkedMethods <- forM methods $ \(CapturedMethod n description implementation) -> do
      let located = either (Left . ((name ++ "/" ++ n ++ ": ") ++)) Right
      checkedMethod <- located (methodName n)
      _ <- located (bindingModule implementation)
      pure (CapturedMethodDeclaration checkedMethod description implementation)
    pure (ConnectorDeclaration checkedName fetch validate checkedMethods login)
  where
    connector = withObject "source connector" $ \fields -> do
      unless (sort (Keys.keys fields) == ["fetch","login","methods","name","validateConfig"])
        (fail "Unexpected or missing source connector fields")
      SourceConnector <$> fields .: "name"
        <*> fields .: "fetch" <*> fields .: "validateConfig" <*> (fields .: "methods" >>= traverse method)
        <*> (fields .: "login" >>= optional)
    optional = withObject "optional export" $ \value -> do
      tag <- value .: "tag"
      case tag :: String of
        "None" | Keys.keys value == ["tag"] -> pure Nothing
        "Some" | sort (Keys.keys value) == ["tag","value"] -> Just <$> value .: "value"
        _ -> fail "Invalid optional export"
    method = withObject "captured method" $ \fields -> do
      unless (sort (Keys.keys fields) == ["description","implementation","name"])
        (fail "Unexpected or missing captured method fields")
      CapturedMethod <$> fields .: "name" <*> fields .: "description" <*> fields .: "implementation"
