{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Plumbing.Capability.GuestCompilation.Types
  ( GuestSources, guestSources, sourceFiles, selectedBuild, sourceIdentity
  , GuestSelection(..), DiscoverySelection(..), bindingModule
  ) where

import Control.Monad (unless, forM_)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.Aeson (Value(..), eitherDecodeStrict', encode)
import qualified Data.Aeson.KeyMap as Keys
import Data.ByteString (ByteString)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.List (isPrefixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import System.FilePath (isAbsolute, normalise, splitDirectories)
import Kyyn.Domain.Path
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Plugin (bindingModule)
import Kyyn.Domain.Root (isRootMaterial)
import Kyyn.Types.GuestBuild

data GuestSources = GuestSources GuestSelection FileTree deriving (Eq, Show)

-- Only source/configuration reaches Nix. Known KB runtime material and local
-- build caches are excluded even if accidentally included by the caller.
guestSources :: GuestSelection -> [(RelativePath, ByteString)] -> Either String GuestSources
guestSources selection entries = do
  captured <- fileTree [(path,bytes) | (path,bytes) <- entries, permitted path]
  let contents = files captured
  unless (all (\name -> any ((== name) . relativeName . fst) contents) ["flake.nix","flake.lock"])
    (Left "Guest source requires flake.nix and flake.lock; update the KB lock explicitly before checking")
  unless (all ((/= ".kyyn-build.json") . relativeName . fst) contents)
    (Left ".kyyn-build.json is reserved for the host's fixed build selection")
  forM_ [bytes | (path,bytes) <- contents, relativeName path == "flake.lock"] $ \bytes ->
    eitherDecodeStrict' bytes >>= checkLockedPaths
  request <- relativePath ".kyyn-build.json"
  selected <- fileTree ((request,Lazy.toStrict (encode selection)) : contents)
  pure (GuestSources selection selected)
  where
    permitted path = not (isRootMaterial path) && all allowed (splitDirectories (relativeName path))
    allowed component = component `notElem` [".git",".kyyn",".kyyn-generated",".build","dist-newstyle",".stack-work","result"]
      && component /= ".env" && not (".env." `isPrefixOf` component)

-- Local dependencies must be within the captured tree. Other locked input kinds
-- are resolved and verified by Nix itself; Kyyn does not implement a lock resolver.
checkLockedPaths :: Value -> Either String ()
checkLockedPaths (Object fields) = do
  case (Keys.lookup "type" fields,Keys.lookup "path" fields) of
    (Just (String "path"),Just (String path)) -> do
      let name = Text.unpack path
      unless (not (isAbsolute name) && ".." `notElem` splitDirectories name)
        (Left "Local flake dependencies must be inside the captured source tree")
      _ <- relativePath (normalise name)
      pure ()
    _ -> pure ()
  mapM_ checkLockedPaths fields
checkLockedPaths (Array values) = mapM_ checkLockedPaths values
checkLockedPaths _ = pure ()

sourceFiles :: GuestSources -> [(RelativePath, ByteString)]
sourceFiles (GuestSources _ tree) = files tree

selectedBuild :: GuestSources -> GuestSelection
selectedBuild (GuestSources selection _) = selection

sourceIdentity :: GuestSources -> ByteString
sourceIdentity sources = SHA256.hash . Lazy.toStrict . Builder.toLazyByteString $
  Builder.byteString "kyyn-nix-guest-sources\0" <>
  foldMap (\(name,bytes) -> framed (Text.encodeUtf8 (Text.pack (relativeName name))) <> framed bytes) (sourceFiles sources)
  where framed bytes = Builder.word64BE (fromIntegral (Bytes.length bytes)) <> Builder.byteString bytes
