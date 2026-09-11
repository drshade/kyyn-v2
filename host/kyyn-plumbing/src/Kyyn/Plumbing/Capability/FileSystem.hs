{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.FileSystem
  ( FileSystem(..), withTemporaryScope, readBytes, readOptionalBytes, writeBytes, replaceBytes, readTree, readSourceTree, listDirectory, entryExists, createUniqueDirectory, createDirectory, ensureDirectory ) where

import Data.ByteString (ByteString)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Path (DirectoryScope, RelativePath)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Diagnostic (Diagnostic)

data FileSystem :: Effect where
  WithTemporaryScope :: (DirectoryScope -> m a) -> FileSystem m a
  ReadBytes :: DirectoryScope -> RelativePath -> FileSystem m ByteString
  ReadOptionalBytes :: DirectoryScope -> RelativePath -> FileSystem m (Maybe ByteString)
  WriteBytes :: DirectoryScope -> RelativePath -> ByteString -> FileSystem m ()
  ReplaceBytes :: DirectoryScope -> RelativePath -> ByteString -> FileSystem m ()
  ReadTree :: DirectoryScope -> FileSystem m FileTree
  ReadSourceTree :: DirectoryScope -> [RelativePath] -> FileSystem m (Either [Diagnostic] FileTree)
  ListDirectory :: DirectoryScope -> FileSystem m (Maybe [RelativePath])
  EntryExists :: DirectoryScope -> RelativePath -> FileSystem m Bool
  CreateUniqueDirectory :: DirectoryScope -> FileSystem m RelativePath
  CreateDirectory :: DirectoryScope -> FileSystem m Bool
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

readSourceTree :: FileSystem :> es => DirectoryScope -> [RelativePath] -> Eff es (Either [Diagnostic] FileTree)
readSourceTree scope = send . ReadSourceTree scope

listDirectory :: FileSystem :> es => DirectoryScope -> Eff es (Maybe [RelativePath])
listDirectory = send . ListDirectory

entryExists :: FileSystem :> es => DirectoryScope -> RelativePath -> Eff es Bool
entryExists scope = send . EntryExists scope

createUniqueDirectory :: FileSystem :> es => DirectoryScope -> Eff es RelativePath
createUniqueDirectory = send . CreateUniqueDirectory

createDirectory :: FileSystem :> es => DirectoryScope -> Eff es Bool
createDirectory = send . CreateDirectory

ensureDirectory :: FileSystem :> es => DirectoryScope -> Eff es ()
ensureDirectory = send . EnsureDirectory
