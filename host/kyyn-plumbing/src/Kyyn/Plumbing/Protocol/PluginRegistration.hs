module Kyyn.Plumbing.Protocol.PluginRegistration (registrationSources, decodeConnectors) where

import Control.Monad (unless, forM_)
import Data.Aeson (eitherDecodeStrict, withArray, withObject, (.:))
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.Foldable (toList)
import Data.List (nub, sort)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Domain.Plugin (pluginManifest)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources, bindingModule)
import Kyyn.Types.Plugin (SourceConnector(..))

registrationSources :: String -> [(RelativePath,Bytes.ByteString)] -> Either String GuestSources
registrationSources entryModule sources = do
  _ <- bindingModule (entryModule ++ ".connectors")
  path <- relativePath "KyynPluginRegistrationEntry.hs"
  let adapter = unlines ["module KyynPluginRegistrationEntry where","import qualified " ++ entryModule,
        "import Kyyn.Runtime.PluginRegistration (encodeConnectors)","main :: IO ()",
        "main = either fail putStrLn (encodeConnectors " ++ entryModule ++ ".connectors)"]
  guestSources path (sources ++ [(path, Text.encodeUtf8 (Text.pack adapter))])

decodeConnectors :: Bytes.ByteString -> Either String [SourceConnector]
decodeConnectors bytes = do
  declarations <- eitherDecodeStrict bytes >>= parseEither (withArray "connectors" (traverse connector . toList))
  let names = [name | SourceConnector name _ _ _ _ <- declarations]
  unless (length names == length (nub names)) (Left "Connector type names must be unique within a plugin")
  forM_ declarations $ \(SourceConnector name config payload fetch validate) -> do
    unless (validName name) (Left (name ++ ": connector type name must match [A-Z][A-Za-z0-9_]*"))
    _ <- either (Left . ((name ++ ": configType: ") ++)) Right (pluginManifest "schema" config)
    _ <- either (Left . ((name ++ ": payloadType: ") ++)) Right (pluginManifest "schema" payload)
    _ <- either (Left . ((name ++ ": fetch: ") ++)) Right (bindingModule fetch)
    _ <- either (Left . ((name ++ ": validateConfig: ") ++)) Right (bindingModule validate)
    pure ()
  pure declarations
  where
    connector = withObject "source connector" $ \fields -> do
      unless (sort (Keys.keys fields) == ["configType","fetch","name","payloadType","validateConfig"])
        (fail "Unexpected or missing source connector fields")
      SourceConnector <$> fields .: "name" <*> fields .: "configType" <*> fields .: "payloadType"
        <*> fields .: "fetch" <*> fields .: "validateConfig"
    validName (c:cs) = c `elem` ['A'..'Z'] && all (\x -> x `elem` (['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "_")) cs
    validName [] = False
