module Kyyn.Domain.Tap
  ( TapName, tapName, tapNameText, Tap(..), CatalogueEntry(..), AvailablePlugin(..), qualifiedPlugin
  , firstPartyTap, tapsPath, cataloguePath ) where

import Kyyn.Domain.Git (GitUrl, GitRevision, gitUrl)
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Domain.Plugin (PluginName, pluginName, pluginNameText)

newtype TapName = TapName String deriving (Eq, Show)
data Tap = Tap TapName GitUrl deriving (Eq, Show)
data CatalogueEntry = CatalogueEntry PluginName String GitUrl RelativePath deriving (Eq, Show)
data AvailablePlugin = AvailablePlugin Tap GitRevision CatalogueEntry deriving (Eq, Show)

tapName :: String -> Either String TapName
tapName value = TapName . pluginNameText <$> pluginName value

tapNameText :: TapName -> String
tapNameText (TapName value) = value

qualifiedPlugin :: String -> Either String (TapName, PluginName)
qualifiedPlugin value = case break (== '/') value of
  (tap,'/':name) -> (,) <$> tapName tap <*> pluginName name
  _ -> Left "Expected TAP/PLUGIN"

firstPartyTap :: Tap
firstPartyTap = Tap (TapName "first-party") (either error id (gitUrl "https://github.com/drshade/kyyn-v2"))

tapsPath, cataloguePath :: RelativePath
tapsPath = either error id (relativePath "taps.dhall")
cataloguePath = either error id (relativePath "kyyn-tap.dhall")
