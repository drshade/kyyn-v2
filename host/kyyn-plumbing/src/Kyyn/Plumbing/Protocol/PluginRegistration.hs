module Kyyn.Plumbing.Protocol.PluginRegistration (registrationSources, decodeConnectors) where

import Control.Monad (unless, forM)
import Data.Aeson (eitherDecodeStrict, withArray, withObject, (.:))
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.Foldable (toList)
import Data.List (nub, sort)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Domain.Plugin (ConnectorDeclaration(..), CapturedMethodDeclaration(..), connectorTypeName, qualifiedTypeName, methodName)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources, bindingModule)
import Kyyn.Types.Plugin (SourceConnector(SourceConnector), CapturedMethod(CapturedMethod))

registrationSources :: String -> [(RelativePath,Bytes.ByteString)] -> Either String GuestSources
registrationSources entryModule sources = do
  _ <- bindingModule (entryModule ++ ".connectors")
  path <- relativePath "KyynPluginRegistrationEntry.hs"
  let adapter = unlines ["module KyynPluginRegistrationEntry where","import qualified " ++ entryModule,
        "import Kyyn.Runtime.PluginRegistration (encodeConnectors)","main :: IO ()",
        "main = either fail putStrLn (encodeConnectors " ++ entryModule ++ ".connectors)"]
  guestSources path (sources ++ [(path, Text.encodeUtf8 (Text.pack adapter))])

decodeConnectors :: Bytes.ByteString -> Either String [ConnectorDeclaration]
decodeConnectors bytes = do
  declarations <- eitherDecodeStrict bytes >>= parseEither (withArray "connectors" (traverse connector . toList))
  let names = [name | SourceConnector name _ _ _ _ _ <- declarations]
  unless (length names == length (nub names)) (Left "Connector type names must be unique within a plugin")
  forM declarations $ \(SourceConnector name config payload fetch validate methods) -> do
    checkedName <- connectorTypeName name
    checkedConfig <- either (Left . ((name ++ ": configType: ") ++)) Right (qualifiedTypeName config)
    checkedPayload <- either (Left . ((name ++ ": payloadType: ") ++)) Right (qualifiedTypeName payload)
    _ <- either (Left . ((name ++ ": fetch: ") ++)) Right (bindingModule fetch)
    _ <- either (Left . ((name ++ ": validateConfig: ") ++)) Right (bindingModule validate)
    let methodNames = [n | CapturedMethod n _ _ _ _ <- methods]
    unless (length methodNames == length (nub methodNames)) (Left (name ++ ": Method names must be unique"))
    checkedMethods <- forM methods $ \(CapturedMethod n description input result implementation) -> do
      let located = either (Left . ((name ++ "/" ++ n ++ ": ") ++)) Right
      checkedMethod <- located (methodName n)
      arguments <- located (qualifiedTypeName input)
      output <- located (qualifiedTypeName result)
      _ <- located (bindingModule implementation)
      pure (CapturedMethodDeclaration checkedMethod description arguments output implementation)
    pure (ConnectorDeclaration checkedName checkedConfig checkedPayload fetch validate checkedMethods)
  where
    connector = withObject "source connector" $ \fields -> do
      unless (sort (Keys.keys fields) == ["configType","fetch","methods","name","payloadType","validateConfig"])
        (fail "Unexpected or missing source connector fields")
      SourceConnector <$> fields .: "name" <*> fields .: "configType" <*> fields .: "payloadType"
        <*> fields .: "fetch" <*> fields .: "validateConfig" <*> (fields .: "methods" >>= traverse method)
    method = withObject "captured method" $ \fields -> do
      unless (sort (Keys.keys fields) == ["description","implementation","inputType","name","resultType"])
        (fail "Unexpected or missing captured method fields")
      CapturedMethod <$> fields .: "name" <*> fields .: "description" <*> fields .: "inputType"
        <*> fields .: "resultType" <*> fields .: "implementation"
