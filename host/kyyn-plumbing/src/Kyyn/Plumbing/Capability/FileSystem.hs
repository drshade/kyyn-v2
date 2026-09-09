{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.FileSystem
  ( FileSystem(..), withTemporaryScope, readBytes, readOptionalBytes, writeBytes, replaceBytes, readTree, listDirectory, createUniqueDirectory, ensureDirectory ) where

import Data.ByteString (ByteString)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Path (DirectoryScope, RelativePath)
import Kyyn.Domain.FileTree (FileTree)

data FileSystem :: Effect where
  WithTemporaryScope :: (DirectoryScope -> m a) -> FileSystem m a
  ReadBytes :: DirectoryScope -> RelativePath -> FileSystem m ByteString
  ReadOptionalBytes :: DirectoryScope -> RelativePath -> FileSystem m (Maybe ByteString)
  WriteBytes :: DirectoryScope -> RelativePath -> ByteString -> FileSystem m ()
  ReplaceBytes :: DirectoryScope -> RelativePath -> ByteString -> FileSystem m ()
  ReadTree :: DirectoryScope -> FileSystem m FileTree
  ListDirectory :: DirectoryScope -> FileSystem m (Maybe [RelativePath])
  CreateUniqueDirectory :: DirectoryScope -> FileSystem m RelativePath
  EnsureDirectory :: DirectoryScope -> FileSystem m ()

type instance DispatchOf FileSystem = Dynamic

withTemporaryScope :: FileSystem :> es => (DirectoryScope -> Eff es a) -> Eff es a
withTemporaryScope = send . WithTemporaryScope

readBytes :: FileSystem :> es => DirectoryScope -> RelativePath -> Eff es ByteString
readBytes scope = send . ReadBytes scope

readOptionalBytes :: FileSystem :> es => DirectoryScope -> RelativePath -> Eff es (Maybe ByteString)
readOptionalBytes scope = send . ReadOptionalBytes scope

writeBytes :: FileSystem :> es => DirectoryScope -> RelativePath -> ByteString -> Eff es ()
writeBytes scope path = send . WriteBytes scope path

replaceBytes :: FileSystem :> es => DirectoryScope -> RelativePath -> ByteString -> Eff es ()
replaceBytes scope path = send . ReplaceBytes scope path

readTree :: FileSystem :> es => DirectoryScope -> Eff es FileTree
readTree = send . ReadTree

listDirectory :: FileSystem :> es => DirectoryScope -> Eff es (Maybe [RelativePath])
listDirectory = send . ListDirectory

createUniqueDirectory :: FileSystem :> es => DirectoryScope -> Eff es RelativePath
createUniqueDirectory = send . CreateUniqueDirectory

ensureDirectory :: FileSystem :> es => DirectoryScope -> Eff es ()
ensureDirectory = send . EnsureDirectory
