{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.DocumentPersistence
  ( DocumentPersistence(..), DocumentAccess(..), DocumentStamp(..)
  , withLockedDocument, readCurrent, replaceCurrent, clearCurrent, freshStamp
  ) where

import Data.ByteString (ByteString)
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Path (DirectoryScope, RelativePath)

data DocumentStamp = DocumentStamp
  { identity :: String
  , timestamp :: String
  } deriving (Eq, Show)

-- | Hold the scope's exclusive lock throughout the action.
data DocumentPersistence :: Effect where
  WithLockedDocument :: DirectoryScope -> RelativePath -> Eff (DocumentAccess : es) a -> DocumentPersistence (Eff es) a
type instance DispatchOf DocumentPersistence = Dynamic

data DocumentAccess :: Effect where
  ReadCurrent :: DocumentAccess m (Maybe ByteString)
  -- | Replace by writing a temporary file and renaming it within the locked directory.
  ReplaceCurrent :: ByteString -> DocumentAccess m ()
  -- | Remove the scoped directory and its contents, returning whether it existed.
  ClearCurrent :: DocumentAccess m Bool
  FreshStamp :: DocumentAccess m DocumentStamp
type instance DispatchOf DocumentAccess = Dynamic

withLockedDocument :: DocumentPersistence :> es => DirectoryScope -> RelativePath -> Eff (DocumentAccess : es) a -> Eff es a
withLockedDocument scope name action = send (WithLockedDocument scope name action)
readCurrent :: DocumentAccess :> es => Eff es (Maybe ByteString)
readCurrent = send ReadCurrent
replaceCurrent :: DocumentAccess :> es => ByteString -> Eff es ()
replaceCurrent = send . ReplaceCurrent
clearCurrent :: DocumentAccess :> es => Eff es Bool
clearCurrent = send ClearCurrent
freshStamp :: DocumentAccess :> es => Eff es DocumentStamp
freshStamp = send FreshStamp
