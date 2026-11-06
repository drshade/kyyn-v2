{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Build.Plugins
  ( PluginSource(..), RegisteredPlugin(..), discoverPlugins, bootstrapPlugins ) where

import Control.Monad (unless, forM, forM_, void)
import Data.Aeson (eitherDecodeStrict')
import qualified Data.ByteString as Bytes
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (sort, nub, intercalate)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import System.Process (callProcess)
import Kyyn.Build.Manifest (parsePluginManifest, qualifiedReference)
import qualified Kyyn.Types.Plugin as P

data PluginSource = PluginSource
  { pluginName :: Text, entryModule :: Text, sourceRoot :: FilePath }
  deriving (Eq, Show)
data RegisteredPlugin = RegisteredPlugin PluginSource [P.Connector] deriving (Eq, Show)

discoverPlugins :: IO [PluginSource]
discoverPlugins = do
  let packages = "plugins/packages"
  exists <- doesDirectoryExist packages
  if not exists then pure [] else do
    names <- sort <$> listDirectory packages
    forM names $ \directory -> do
      let source = packages </> directory </> "source"
      (name,entry) <- Text.readFile (source </> "kyyn-plugin.dhall") >>= either fail pure . parsePluginManifest
      unless (name == Text.pack directory) (fail "Installed plugin directory disagrees with its manifest name")
      pure (PluginSource name entry (source </> "src"))

-- The fixed adapter evaluates only the registration values. GHC, in the KB's
-- locked environment, supplies their types; no host compiler is involved.
bootstrapPlugins :: ([FilePath] -> FilePath -> FilePath -> IO ())
  -> FilePath -> [PluginSource] -> IO [RegisteredPlugin]
bootstrapPlugins _ _ [] = pure []
bootstrapPlugins compile generated sources = do
  let entry = generated </> "KyynGuestRegistrations.hs"
      executable = generated </> "registrations-entry"
      result = generated </> "registrations.json"
      aliases = zip sources [0 :: Int ..]
  writeFile entry (unlines
    (["{-# LANGUAGE OverloadedStrings #-}","module KyynGuestRegistrations where",
      "import qualified Data.Aeson as Json", "import qualified Data.ByteString.Lazy as Bytes",
      "import Data.Text (Text)", "import Kyyn.Types.Plugin (Connector)"] ++
     ["import qualified " ++ Text.unpack source.entryModule ++ " as P" ++ show index | (source,index) <- aliases] ++
     ["registrations :: [(Text,[Connector])]", "registrations = [" ++ intercalate ","
       ["(" ++ show source.pluginName ++ ",P" ++ show index ++ ".connectors)" | (source,index) <- aliases] ++ "]",
      "main :: IO ()", "main = Bytes.writeFile " ++ show result ++ " (Json.encode registrations)"]))
  compile (map sourceRoot sources) entry executable
  callProcess ("./" ++ executable) []
  decoded <- Bytes.readFile result >>= either fail pure . eitherDecodeStrict'
  unless (map fst decoded == map pluginName sources) (fail "Registration bootstrap changed plugin identities")
  forM (zip sources (map snd decoded)) $ \(source,connectors) -> do
    either (fail . ((Text.unpack source.pluginName ++ ": ") ++)) pure (validate connectors)
    pure (RegisteredPlugin source connectors)

validate :: [P.Connector] -> Either String ()
validate connectors = do
  unique "connector" [connector.name | connector <- connectors]
  forM_ connectors $ \connector -> do
    unless (identifier isAsciiUpper connector.name && not (Text.any (== '\'') connector.name))
      (Left "Connector type name must match [A-Z][A-Za-z0-9_]*")
    reference connector.validateConfig
    case connector of
      P.SourceConnector _ fetch _ methods login -> do
        reference fetch
        mapM_ reference login
        unique "method" [method.methodName | method <- methods]
        forM_ methods $ \method -> do
          unless (identifier isAsciiLower method.methodName) (Left "Invalid captured method name")
          reference method.implementation
      P.SinkConnector _ _ publish defaults -> reference publish >> reference defaults
  where
    reference = void . qualifiedReference False
    unique label names = unless (length names == length (nub names)) (Left ("Duplicate " ++ label ++ " names"))
    identifier first text = case Text.uncons text of
      Just (c,rest) -> first c && Text.all (\x -> isAsciiLower x || isAsciiUpper x || isDigit x || x `elem` ['_','\'']) rest
      Nothing -> False
