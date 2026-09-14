{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.DocumentPersistence
  ( DocumentPersistence(..), DocumentAccess(..), DocumentStamp(..)
  , withLockedDocument, readCurrent, replaceCurrent, archiveCurrent, clearCurrent, clearArchives, freshStamp
  ) where

import Data.ByteString (ByteString)
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Path (DirectoryScope)

data DocumentStamp = DocumentStamp
  { identity :: String
  , timestamp :: String
  } deriving (Eq, Show)

-- | Ensure the directory exists and hold its exclusive lock throughout the action.
data DocumentPersistence :: Effect where
  WithLockedDocument :: DirectoryScope -> Eff (DocumentAccess : es) a -> DocumentPersistence (Eff es) a
type instance DispatchOf DocumentPersistence = Dynamic

data DocumentAccess :: Effect where
  ReadCurrent :: DocumentAccess m (Maybe ByteString)
  -- | Replace by writing a temporary file and renaming it within the locked directory.
  ReplaceCurrent :: ByteString -> DocumentAccess m ()
  -- | Retain the supplied document in an archive named by a fresh identity.
  ArchiveCurrent :: ByteString -> DocumentAccess m ()
  ClearCurrent :: DocumentAccess m ()
  ClearArchives :: DocumentAccess m ()
  FreshStamp :: DocumentAccess m DocumentStamp
type instance DispatchOf DocumentAccess = Dynamic

withLockedDocument :: DocumentPersistence :> es => DirectoryScope -> Eff (DocumentAccess : es) a -> Eff es a
withLockedDocument scope action = send (WithLockedDocument scope action)
readCurrent :: DocumentAccess :> es => Eff es (Maybe ByteString)
readCurrent = send ReadCurrent
replaceCurrent :: DocumentAccess :> es => ByteString -> Eff es ()
replaceCurrent = send . ReplaceCurrent
archiveCurrent :: DocumentAccess :> es => ByteString -> Eff es ()
archiveCurrent = send . ArchiveCurrent
clearCurrent :: DocumentAccess :> es => Eff es ()
clearCurrent = send ClearCurrent
clearArchives :: DocumentAccess :> es => Eff es ()
clearArchives = send ClearArchives
freshStamp :: DocumentAccess :> es => Eff es DocumentStamp
freshStamp = send FreshStamp
