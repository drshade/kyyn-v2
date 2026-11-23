{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, TypeApplications, OverloadedRecordDot #-}
module Kyyn.Interactive.Event (EventRef(..), EventBinding(..), eventRef, event) where

import Data.Text (Text)
import Kyyn.Contract
import Kyyn.Plugin.Event (LiveEvent, EventPoll, EventBatch)
import Kyyn.Types.Plugin (ConnectorInstance(..), FetchError)
import Kyyn.Types.KnowledgeBase (EventReference(EventReference))

-- The constructor belongs to the internal SDK; authors use generated bindings.
data EventRef request reply = EventRef EventReference (Either ProjectionError (CompiledContract request, CompiledContract reply))
newtype EventBinding = EventBinding EventReference

event :: EventRef request reply -> EventBinding
event (EventRef reference _) = EventBinding reference

-- The poll export is an unevaluated type witness. Its configuration and cursor
-- never become part of the flow author's API.
eventRef :: forall config request cursor reply connector. (Contract request, Contract reply)
  => Text -> Text -> Text
  -> (config -> EventPoll request cursor -> LiveEvent (Either FetchError (EventBatch reply cursor)))
  -> ConnectorInstance connector -> EventRef request reply
eventRef plugin connector method _ (ConnectorInstance instanceName) =
  EventRef (EventReference plugin connector instanceName method)
    ((,) <$> compileContract (contract @request) <*> compileContract (contract @reply))
