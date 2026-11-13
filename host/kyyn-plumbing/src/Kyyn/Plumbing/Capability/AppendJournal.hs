{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Plumbing.Capability.AppendJournal
  ( AppendJournal(..), JournalStamp(..), JournalExit(..), JournalSnapshot(..)
  , withJournal, appendJournal, readJournal, listJournals, clearJournal ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Numeric.Natural (Natural)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Path (DirectoryScope, RelativePath)

data JournalStamp = JournalStamp RelativePath Text deriving (Eq, Show)
data JournalExit = JournalCancelled | JournalException String deriving (Eq, Show)
data JournalSnapshot = JournalSnapshot ByteString [ByteString] Bool Bool deriving (Eq, Show)

data AppendJournal :: Effect where
  WithJournal :: DirectoryScope -> (JournalStamp -> ByteString)
    -> (JournalStamp -> JournalExit -> m ()) -> (JournalStamp -> m a) -> AppendJournal m a
  AppendJournal :: DirectoryScope -> RelativePath -> Bool -> (Natural -> ByteString) -> AppendJournal m Natural
  ReadJournal :: DirectoryScope -> RelativePath -> AppendJournal m JournalSnapshot
  ListJournals :: DirectoryScope -> AppendJournal m [RelativePath]
  ClearJournal :: DirectoryScope -> RelativePath -> AppendJournal m ()
type instance DispatchOf AppendJournal = Dynamic
withJournal :: AppendJournal :> es => DirectoryScope -> (JournalStamp -> ByteString)
  -> (JournalStamp -> JournalExit -> Eff es ()) -> (JournalStamp -> Eff es a) -> Eff es a
withJournal directory header cleanup = send . WithJournal directory header cleanup
appendJournal :: AppendJournal :> es => DirectoryScope -> RelativePath -> Bool -> (Natural -> ByteString) -> Eff es Natural
appendJournal directory name terminal = send . AppendJournal directory name terminal
readJournal :: AppendJournal :> es => DirectoryScope -> RelativePath -> Eff es JournalSnapshot
readJournal directory = send . ReadJournal directory
listJournals :: AppendJournal :> es => DirectoryScope -> Eff es [RelativePath]
listJournals = send . ListJournals
clearJournal :: AppendJournal :> es => DirectoryScope -> RelativePath -> Eff es ()
clearJournal directory = send . ClearJournal directory
