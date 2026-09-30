{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.FileSystem
  ( FileSystem(..), withTemporaryScope, readBytes, readOptionalBytes, writeBytes, replaceBytes, replaceTree, readTree, listDirectory, entryExists, directoryExists, createUniqueDirectory, createDirectory, ensureDirectory, ensureIgnoredDirectory ) where

import Data.ByteString (ByteString)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Path (DirectoryScope, RelativePath, relativePath, relativeName)
import Kyyn.Domain.FileTree (FileTree)

data FileSystem :: Effect where
  WithTemporaryScope :: (DirectoryScope -> m a) -> FileSystem m a
  ReadBytes :: DirectoryScope -> RelativePath -> FileSystem m ByteString
  ReadOptionalBytes :: DirectoryScope -> RelativePath -> FileSystem m (Maybe ByteString)
  WriteBytes :: DirectoryScope -> RelativePath -> ByteString -> FileSystem m ()
  ReplaceBytes :: DirectoryScope -> RelativePath -> ByteString -> FileSystem m ()
  ReplaceTree :: DirectoryScope -> RelativePath -> FileTree -> FileSystem m ()
  ReadTree :: DirectoryScope -> FileSystem m FileTree
  ListDirectory :: DirectoryScope -> FileSystem m (Maybe [RelativePath])
  EntryExists :: DirectoryScope -> RelativePath -> FileSystem m Bool
  DirectoryExists :: DirectoryScope -> FileSystem m Bool
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

replaceTree :: FileSystem :> es => DirectoryScope -> RelativePath -> FileTree -> Eff es ()
replaceTree scope path = send . ReplaceTree scope path

readTree :: FileSystem :> es => DirectoryScope -> Eff es FileTree
readTree = send . ReadTree

listDirectory :: FileSystem :> es => DirectoryScope -> Eff es (Maybe [RelativePath])
listDirectory = send . ListDirectory

entryExists :: FileSystem :> es => DirectoryScope -> RelativePath -> Eff es Bool
entryExists scope = send . EntryExists scope

directoryExists :: FileSystem :> es => DirectoryScope -> Eff es Bool
directoryExists = send . DirectoryExists

createUniqueDirectory :: FileSystem :> es => DirectoryScope -> Eff es RelativePath
createUniqueDirectory = send . CreateUniqueDirectory

createDirectory :: FileSystem :> es => DirectoryScope -> Eff es Bool
createDirectory = send . CreateDirectory

ensureDirectory :: FileSystem :> es => DirectoryScope -> Eff es ()
ensureDirectory = send . EnsureDirectory

ensureIgnoredDirectory :: FileSystem :> es => DirectoryScope -> RelativePath -> Eff es ()
ensureIgnoredDirectory scope directory = do
  let ignore = either error id (relativePath (relativeName directory ++ "/.gitignore"))
  existing <- readOptionalBytes scope ignore
  case existing of
    Nothing -> writeBytes scope ignore "*\n"
    Just _ -> pure ()
