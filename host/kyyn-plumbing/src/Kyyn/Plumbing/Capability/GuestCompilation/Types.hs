{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Plumbing.Capability.GuestCompilation.Types
  ( GuestSources, guestSources, sourceFiles, selectedEntry, sourceIdentity
  , packageIdentity, bindingModule ) where

import qualified Crypto.Hash.SHA256 as SHA256
import Data.ByteString (ByteString)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.List (sortOn, nub, isPrefixOf, isSuffixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin (PackageIdentity(..), bindingModule)
import Numeric (showHex)

data GuestSources = GuestSources RelativePath [(RelativePath, ByteString)] deriving (Eq, Show)

guestSources :: RelativePath -> [(RelativePath, ByteString)] -> Either String GuestSources
guestSources entry files
  | entry `notElem` paths = Left "selected entry is absent from captured sources"
  | length (nub paths) /= length paths = Left "duplicate captured source path"
  | or [ (relativeName a ++ "/") `isPrefixOf` relativeName b | a <- paths, b <- paths ] =
      Left "captured source file/directory collision"
  | path : _ <- unsupported = Left ("unsupported Haskell source format; use .hs: " ++ path)
  | otherwise = Right (GuestSources entry (sortOn fst files))
  where
    paths = map fst files
    unsupported = [name | p <- paths, let name = relativeName p,
      any (`isSuffixOf` name) [".lhs",".hsc"]]

sourceFiles :: GuestSources -> [(RelativePath, ByteString)]
sourceFiles (GuestSources _ files) = files

packageIdentity :: GuestSources -> PackageIdentity
packageIdentity = PackageIdentity . concatMap hex . Bytes.unpack . sourceIdentity
  where hex byte = let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits

selectedEntry :: GuestSources -> RelativePath
selectedEntry (GuestSources entry _) = entry

sourceIdentity :: GuestSources -> ByteString
sourceIdentity (GuestSources entry files) = SHA256.hash . Lazy.toStrict . Builder.toLazyByteString $
  Builder.byteString "kyyn-guest-sources\0" <> path entry <>
  foldMap (\(name, bytes) -> path name <> framed bytes) files
  where
    path = framed . Text.encodeUtf8 . Text.pack . relativeName
    framed bytes = Builder.word64BE (fromIntegral (Bytes.length bytes)) <> Builder.byteString bytes
