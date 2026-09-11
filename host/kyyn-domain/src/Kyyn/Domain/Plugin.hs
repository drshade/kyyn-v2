module Kyyn.Domain.Plugin
  ( PluginName, pluginName, pluginNameText, GitUrl, gitUrl, gitUrlText
  , PluginSource(..), pluginSource, PluginManifest, pluginManifest, manifestName, entryModule
  , InstalledPlugin(..)
  ) where

import Data.Char (isAlphaNum, isUpper)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import Kyyn.Domain.Git (TreePath)
import Kyyn.Domain.Path (DirectoryScope, directoryScope, scopePath)
import System.FilePath (isAbsolute, (</>))

newtype PluginName = PluginName String deriving (Eq, Show)
newtype GitUrl = GitUrl String deriving (Eq, Show)
data PluginSource = LocalPackage DirectoryScope TreePath | GitPackage GitUrl TreePath deriving (Eq, Show)
data PluginManifest = PluginManifest PluginName String deriving (Eq, Show)
data InstalledPlugin = InstalledPlugin PluginName DirectoryScope PluginSource deriving (Eq, Show)

pluginNameText :: PluginName -> String
pluginNameText (PluginName value) = value

pluginName :: String -> Either String PluginName
pluginName value
  | not (null value), all valid value, not ("-" `isPrefixOf` value), not ("-" `isSuffixOf` value), not ("--" `isInfixOf` value) = Right (PluginName value)
  | otherwise = Left "Plugin name must contain lowercase ASCII letters or digits separated by single hyphens"
  where valid c = c `elem` ['a'..'z'] || c `elem` ['0'..'9'] || c == '-'

gitUrlText :: GitUrl -> String
gitUrlText (GitUrl value) = value

gitUrl :: String -> Either String GitUrl
gitUrl value
  | any (\prefix -> prefix `isPrefixOf` value && length value > length prefix) ["file://", "https://"]
  , not (any (`elem` value) ['\0', '\n', '\r']) = Right (GitUrl value)
  | otherwise = Left "Use a file:// or unauthenticated https:// Git URL, or a local package directory"

pluginSource :: DirectoryScope -> String -> TreePath -> Either String PluginSource
pluginSource cwd value path
  | "://" `isInfixOf` value = (\url -> GitPackage url path) <$> gitUrl value
  | ':' `elem` value = Left "Scp-style sources are unsupported; use HTTPS or a local checkout"
  | null value = Left "Plugin source must not be empty"
  | otherwise = (\scope -> LocalPackage scope path) <$> directoryScope
      (if isAbsolute value then value else scopePath cwd </> value)

pluginManifest :: String -> String -> Either String PluginManifest
pluginManifest name entry = do
  checkedName <- pluginName name
  if all validComponent (components entry) then Right (PluginManifest checkedName entry)
  else Left "entryModule must be a dotted Haskell module name"
  where
    validComponent (c:cs) = isUpper c && all (\x -> isAlphaNum x || x `elem` "_'") cs
    validComponent [] = False
    components text = case break (== '.') text of
      (part,[]) -> [part]
      (part,_:rest) -> part : components rest

manifestName :: PluginManifest -> PluginName
manifestName (PluginManifest name _) = name

entryModule :: PluginManifest -> String
entryModule (PluginManifest _ entry) = entry
