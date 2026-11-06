module Kyyn.Domain.Plugin
  ( PluginName, pluginName, pluginNameText, PackageIdentity(..), packageIdentity
  , PluginSource(..), pluginSource, PluginManifest, pluginManifest, manifestName, entryModule
  , PluginRepository(..), PluginOrigin(..), InstalledPlugin(..)
  , PluginDescription(..), PluginGuide(..)
  , ConnectorTypeName(..), BindingName(..), ConnectorName(..), QualifiedTypeName(..), ConnectorDeclaration(..)
  , CapturedMethodDeclaration(..), MethodName(..), methodName, connectorTypeName, bindingName, connectorName, qualifiedTypeName
  , PluginEntryKind(..), PluginSignature(..), expectedPluginSignature, bindingModule
  ) where

import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Numeric (showHex)
import Kyyn.Domain.FileTree (FileTree, files)
import Data.Char (isAlphaNum, isUpper, isAsciiLower, isAsciiUpper, isDigit)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import Kyyn.Domain.Git (TreePath, GitRevision, GitUrl, gitUrl)
import Kyyn.Domain.DataType (DataType)
import Kyyn.Domain.Path (DirectoryScope, directoryScope, scopePath, relativeName)
import System.FilePath (isAbsolute, (</>))

newtype PluginName = PluginName String deriving (Eq, Show)
newtype PackageIdentity = PackageIdentity String deriving (Eq, Show)
-- Installed package provenance is independent of the selected compiler entry.
-- Build identity separately captures the complete KB source and locked environment.
packageIdentity :: FileTree -> PackageIdentity
packageIdentity tree = PackageIdentity (concatMap hex (Bytes.unpack digest))
  where
    digest = SHA256.hash . Lazy.toStrict . Builder.toLazyByteString $
      Builder.byteString (Text.encodeUtf8 (Text.pack "kyyn-plugin-source\0")) <>
      foldMap (\(path,bytes) -> framed (Text.encodeUtf8 (Text.pack (relativeName path))) <> framed bytes) (files tree)
    framed bytes = Builder.word64BE (fromIntegral (Bytes.length bytes)) <> Builder.byteString bytes
    hex byte = let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits

newtype ConnectorTypeName = ConnectorTypeName String deriving (Eq, Show)
newtype BindingName = BindingName String deriving (Eq, Show)
newtype MethodName = MethodName String deriving (Eq, Show)
newtype ConnectorName = ConnectorName String deriving (Eq, Show)
newtype QualifiedTypeName = QualifiedTypeName String deriving (Eq, Show)
data PluginEntryKind = AcquisitionEntry | CapturedReadEntry | SinkEntry deriving (Eq, Show)
data PluginSignature
  = FetchSignature DataType (Maybe DataType) DataType
  | StatefulFetchSignature DataType (Maybe DataType) DataType DataType DataType
  | ReadSignature DataType DataType DataType
  | SinkSignature DataType DataType DataType DataType
  deriving (Eq, Show)

expectedPluginSignature :: PluginEntryKind -> String
expectedPluginSignature AcquisitionEntry = "Config -> [Maybe Options ->] [FetchContext Position ->] EvidenceSnapshot Payload -> Acquisition Payload (Either FetchError result), where result is [EvidenceChange Payload] without context or FetchResult Payload Position Report with context"
expectedPluginSignature CapturedReadEntry = "Input -> EvidenceSnapshot Payload -> CapturedRead Payload (Either FetchError Result)"
expectedPluginSignature SinkEntry = "Config -> Options -> Input -> Sink (Either SinkError Result)"
data ConnectorDeclaration = ConnectorDeclaration ConnectorTypeName String String [CapturedMethodDeclaration] (Maybe String)
  | SinkDeclaration ConnectorTypeName String String String deriving (Eq, Show)
data CapturedMethodDeclaration = CapturedMethodDeclaration MethodName String String deriving (Eq, Show)

methodName :: String -> Either String MethodName
methodName value = (\(BindingName name) -> MethodName name) <$> bindingName value

connectorTypeName :: String -> Either String ConnectorTypeName
connectorTypeName value
  | identifier isAsciiUpper value && '\'' `notElem` value = Right (ConnectorTypeName value)
  | otherwise = Left "Connector type name must match [A-Z][A-Za-z0-9_]*"

bindingName :: String -> Either String BindingName
bindingName value
  | identifier isAsciiLower value && value `notElem` keywords = Right (BindingName value)
  | otherwise = Left "Binding must match [a-z][A-Za-z0-9_']* and must not be a Haskell keyword"
  where keywords = ["case","class","data","default","deriving","do","else","foreign","if","import",
          "in","infix","infixl","infixr","instance","let","module","newtype","of","then","type","where",
          "qualified","as","hiding","forall","mdo","rec","pattern"]

connectorName :: String -> Either String ConnectorName
connectorName value | null value = Left "Instance name must not be empty"
                    | otherwise = Right (ConnectorName value)

qualifiedTypeName :: String -> Either String QualifiedTypeName
qualifiedTypeName value
  | length (segments value) >= 2 && all (identifier isAsciiUpper) (segments value) = Right (QualifiedTypeName value)
  | otherwise = Left "Expected a qualified Haskell type name: uppercase module and type identifiers separated by dots"

bindingModule :: String -> Either String String
bindingModule selected = case reverse (segments selected) of
  binding : modules@(_:_) | identifier isAsciiLower binding && all (identifier isAsciiUpper) modules ->
    Right (take (length selected - length binding - 1) selected)
  _ -> Left "Expected a qualified Haskell binding, such as Schema.validate"

identifier :: (Char -> Bool) -> String -> Bool
identifier first (c:cs) = first c && all (\x -> isAsciiLower x || isAsciiUpper x || isDigit x || x `elem` "_'") cs
identifier _ [] = False

segments :: String -> [String]
segments text = case break (== '.') text of
  (part,[]) -> [part]
  (part,_:rest) -> part : segments rest
data PluginSource = LocalPackage DirectoryScope TreePath | GitPackage GitUrl TreePath deriving (Eq, Show)
data PluginManifest = PluginManifest PluginName String deriving (Eq, Show)
data PluginRepository = LocalRepository DirectoryScope | RemoteRepository GitUrl deriving (Eq, Show)
data PluginOrigin = PluginOrigin PluginRepository TreePath GitRevision deriving (Eq, Show)
data InstalledPlugin = InstalledPlugin PluginName DirectoryScope PluginOrigin deriving (Eq, Show)
data PluginDescription = PluginDescription PluginManifest PluginOrigin Bool deriving (Eq, Show)
data PluginGuide = PluginGuide PluginDescription String deriving (Eq, Show)

pluginNameText :: PluginName -> String
pluginNameText (PluginName value) = value

pluginName :: String -> Either String PluginName
pluginName value
  | not (null value), all valid value, not ("-" `isPrefixOf` value), not ("-" `isSuffixOf` value), not ("--" `isInfixOf` value) = Right (PluginName value)
  | otherwise = Left "Plugin name must contain lowercase ASCII letters or digits separated by single hyphens"
  where valid c = c `elem` ['a'..'z'] || c `elem` ['0'..'9'] || c == '-'

pluginSource :: DirectoryScope -> String -> TreePath -> Either String PluginSource
pluginSource cwd value path
  | "://" `isInfixOf` value = (\url -> GitPackage url path) <$> gitUrl value
  | ':' `elem` value, '/' `notElem` takeWhile (/= ':') value = Left "Scp-style sources are unsupported; use HTTPS or a local checkout"
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
