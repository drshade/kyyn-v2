{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.DocumentPersistence
  ( DocumentPersistence(..), DocumentAccess(..), DocumentStamp(..)
  , withLockedDocument, readCurrent, replaceCurrent, clearCurrent, freshStamp
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
  -- | Remove the scoped document directory and its contents, retaining the lock.
  ClearCurrent :: DocumentAccess m ()
  FreshStamp :: DocumentAccess m DocumentStamp
type instance DispatchOf DocumentAccess = Dynamic

withLockedDocument :: DocumentPersistence :> es => DirectoryScope -> Eff (DocumentAccess : es) a -> Eff es a
withLockedDocument scope action = send (WithLockedDocument scope action)
readCurrent :: DocumentAccess :> es => Eff es (Maybe ByteString)
readCurrent = send ReadCurrent
replaceCurrent :: DocumentAccess :> es => ByteString -> Eff es ()
replaceCurrent = send . ReplaceCurrent
clearCurrent :: DocumentAccess :> es => Eff es ()
clearCurrent = send ClearCurrent
freshStamp :: DocumentAccess :> es => Eff es DocumentStamp
freshStamp = send FreshStamp
