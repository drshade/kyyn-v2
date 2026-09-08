{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Plumbing.Capability.GuestCompilation.Types
  ( GuestSources, guestSources, sourceFiles, selectedEntry, sourceIdentity
  , BuildOptions(..), BuildIdentity(..), CompiledEntry(..) ) where

import qualified Crypto.Hash.SHA256 as SHA256
import Data.ByteString (ByteString)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.List (sortOn, nub, isPrefixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Path

data GuestSources = GuestSources RelativePath [(RelativePath, ByteString)] deriving (Eq, Show)

guestSources :: RelativePath -> [(RelativePath, ByteString)] -> Either String GuestSources
guestSources entry files
  | entry `notElem` paths = Left "selected entry is absent from captured sources"
  | length (nub paths) /= length paths = Left "duplicate captured source path"
  | or [ (relativeName a ++ "/") `isPrefixOf` relativeName b | a <- paths, b <- paths ] =
      Left "captured source file/directory collision"
  | otherwise = Right (GuestSources entry (sortOn fst files))
  where paths = map fst files

sourceFiles :: GuestSources -> [(RelativePath, ByteString)]
sourceFiles (GuestSources _ files) = files

selectedEntry :: GuestSources -> RelativePath
selectedEntry (GuestSources entry _) = entry

sourceIdentity :: GuestSources -> ByteString
sourceIdentity (GuestSources entry files) = SHA256.hash . Lazy.toStrict . Builder.toLazyByteString $
  Builder.byteString "kyyn-guest-sources\0" <> path entry <>
  foldMap (\(name, bytes) -> path name <> framed bytes) files
  where
    path = framed . Text.encodeUtf8 . Text.pack . relativeName
    framed bytes = Builder.word64BE (fromIntegral (Bytes.length bytes)) <> Builder.byteString bytes

data BuildOptions = BuildOptions { compressCombinators :: Bool } deriving (Eq, Show)

data BuildIdentity = BuildIdentity
  { toolchainRevision :: String
  , sourcesDigest :: ByteString
  , options :: BuildOptions
  } deriving (Eq, Show)

data CompiledEntry = CompiledEntry
  { identity :: BuildIdentity
  , artifact :: (RelativePath, ByteString)
  , evaluator :: FilePath
  , arguments :: [String]
  , environment :: [(String, String)]
  }
