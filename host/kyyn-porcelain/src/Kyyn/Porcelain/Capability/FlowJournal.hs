{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.FlowJournal
  (FlowJournal(..), FlowJournalIdentity(..), lookupCompletion, saveCompletion) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)

-- Fixed for the instance, including original request and execution revision.
data FlowJournalIdentity = FlowJournalIdentity
  { namespace :: Text, revision :: Text, input :: Value }
  deriving (Eq, Show)

data FlowJournal :: Effect where
  LookupCompletion :: Value -> FlowJournal m (Maybe Value)
  SaveCompletion :: Value -> Value -> FlowJournal m ()
type instance DispatchOf FlowJournal = Dynamic

lookupCompletion :: FlowJournal :> es => Value -> Eff es (Maybe Value)
lookupCompletion = send . LookupCompletion
saveCompletion :: FlowJournal :> es => Value -> Value -> Eff es ()
saveCompletion key = send . SaveCompletion key
