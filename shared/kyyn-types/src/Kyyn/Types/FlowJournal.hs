{-# LANGUAGE GADTs #-}
module Kyyn.Types.FlowJournal (JournalRequest(..)) where

import Agentic.Journal (JournalIdentity)
import Agentic.Value (Value)

data JournalRequest a where
  InitialiseJournal :: JournalIdentity -> JournalRequest ()
  LookupJournal :: Value -> JournalRequest (Maybe Value)
  SaveJournal :: Value -> Value -> JournalRequest ()
