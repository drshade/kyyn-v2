{-# LANGUAGE GADTs, RankNTypes, OverloadedStrings #-}
module Kyyn.Runtime.FlowJournal (guestJournal, exchangeJournal) where

import Agentic.Journal (Journal(..), JournalIdentity(..))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT)
import Kyyn.Types.Program (Program, request)
import Kyyn.Types.FlowJournal
import Kyyn.Runtime.ModelWire (valueCodec)
import Kyyn.Runtime.Json
import Kyyn.Runtime.Plugin (exchange)
import Kyyn.Runtime.Transport (Transport)

guestJournal :: (forall a. JournalRequest a -> calls a) -> JournalIdentity
  -> Journal (ExceptT error (Program calls))
guestJournal inject identity = Journal identity
  (lift (request (inject (InitialiseJournal identity))))
  (lift . request . inject . LookupJournal)
  (\key value -> lift (request (inject (SaveJournal key value))))

exchangeJournal :: Transport -> Integer -> JournalRequest a -> IO a
exchangeJournal transport requestId call = case call of
  InitialiseJournal (JournalIdentity namespace revision) -> exchange transport requestId "flow-journal" "initialise"
    (record [("namespace",encodeWith textCodec namespace),("revision",encodeWith textCodec revision)]) unit
  LookupJournal key -> exchange transport requestId "flow-journal" "lookup"
    (record [("key",encodeWith valueCodec key)]) (optionalCodec valueCodec)
  SaveJournal key value -> exchange transport requestId "flow-journal" "save"
    (record [("key",encodeWith valueCodec key),("value",encodeWith valueCodec value)]) unit
  where unit = Codec (const (record [])) (\v -> fields [] v >> Right ())
