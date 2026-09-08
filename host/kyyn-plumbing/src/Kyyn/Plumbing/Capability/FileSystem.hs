{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.FileSystem
  ( FileSystem(..), withTemporaryScope, readBytes, writeBytes, readTree, createUniqueDirectory ) where

import Data.ByteString (ByteString)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Path (DirectoryScope, RelativePath)
import Kyyn.Domain.FileTree (FileTree)

data FileSystem :: Effect where
  WithTemporaryScope :: (DirectoryScope -> m a) -> FileSystem m a
  ReadBytes :: DirectoryScope -> RelativePath -> FileSystem m ByteString
  WriteBytes :: DirectoryScope -> RelativePath -> ByteString -> FileSystem m ()
  ReadTree :: DirectoryScope -> FileSystem m FileTree
  CreateUniqueDirectory :: DirectoryScope -> FileSystem m RelativePath

type instance DispatchOf FileSystem = Dynamic

withTemporaryScope :: FileSystem :> es => (DirectoryScope -> Eff es a) -> Eff es a
withTemporaryScope = send . WithTemporaryScope

readBytes :: FileSystem :> es => DirectoryScope -> RelativePath -> Eff es ByteString
readBytes scope = send . ReadBytes scope

writeBytes :: FileSystem :> es => DirectoryScope -> RelativePath -> ByteString -> Eff es ()
writeBytes scope path = send . WriteBytes scope path

readTree :: FileSystem :> es => DirectoryScope -> Eff es FileTree
readTree = send . ReadTree

createUniqueDirectory :: FileSystem :> es => DirectoryScope -> Eff es RelativePath
createUniqueDirectory = send . CreateUniqueDirectory
