{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Plumbing.Capability.GuestCompilation.Types
  ( GuestSources, guestSources, sourceFiles, selectedBuild, sourceIdentity
  , GuestSelection(..), DiscoverySelection(..), RecipeReference(..), EvolutionSelection(..), bindingModule
  ) where

import Control.Monad (unless)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.Aeson (encode)
import Data.ByteString (ByteString)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.List (isPrefixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import System.FilePath (splitDirectories)
import Kyyn.Domain.Path
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Plugin (bindingModule)
import Kyyn.Domain.View (isViewPath)
import Kyyn.Domain.Root (isRootMaterial)
import Kyyn.Types.GuestBuild

data GuestSources = GuestSources GuestSelection FileTree deriving (Eq, Show)

-- Only source/configuration reaches Nix. Known KB runtime material and local
-- build caches are excluded even if accidentally included by the caller.
guestSources :: GuestSelection -> [(RelativePath, ByteString)] -> Either String GuestSources
guestSources requested entries = do
  let selection = canonicalSelection requested
  captured <- fileTree [(path,bytes) | (path,bytes) <- entries, permitted path]
  let contents = files captured
  unless (all (\name -> any ((== name) . relativeName . fst) contents) ["flake.nix","flake.lock"])
    (Left "Guest source requires flake.nix and flake.lock; update the KB lock explicitly before checking")
  unless (all ((/= ".kyyn-build.json") . relativeName . fst) contents)
    (Left ".kyyn-build.json is reserved for the host's fixed build selection")
  request <- relativePath ".kyyn-build.json"
  selected <- fileTree ((request,Lazy.toStrict (encode selection)) : contents)
  pure (GuestSources selection selected)
  where
    permitted path = not (isRootMaterial path) && not (isViewPath path) && all allowed (splitDirectories (relativeName path))
    allowed component = component `notElem` [".git",".kyyn",".kyyn-generated",".build","dist-newstyle",".stack-work","result"]
      && component /= ".env" && not (".env." `isPrefixOf` component)

sourceFiles :: GuestSources -> [(RelativePath, ByteString)]
sourceFiles (GuestSources _ tree) = files tree

selectedBuild :: GuestSources -> GuestSelection
selectedBuild (GuestSources selection _) = selection

sourceIdentity :: GuestSources -> ByteString
sourceIdentity sources = SHA256.hash . Lazy.toStrict . Builder.toLazyByteString $
  Builder.byteString "kyyn-nix-guest-sources\0" <>
  foldMap (\(name,bytes) -> framed (Text.encodeUtf8 (Text.pack (relativeName name))) <> framed bytes) (sourceFiles sources)
  where framed bytes = Builder.word64BE (fromIntegral (Bytes.length bytes)) <> Builder.byteString bytes
