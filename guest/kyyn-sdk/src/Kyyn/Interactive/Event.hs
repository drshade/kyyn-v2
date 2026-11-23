{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, TypeApplications, OverloadedRecordDot #-}
module Kyyn.Interactive.Event (EventRef(..), EventBinding(..), eventRef, event, awaitReply) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Agentic as A
import Control.Monad.Trans.Except (ExceptT, throwE)
import Kyyn.Types.Program (Program)
import Kyyn.Types.EventWait (ReceivedReply, eventRequestCodec, receivedReplyCodec)
import Kyyn.Contract
import Kyyn.Plugin.Event (LiveEvent, EventPoll, EventBatch)
import Kyyn.Types.Plugin (ConnectorInstance(..), FetchError(..))
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

-- | Suspend until a validated provider or manual reply reaches this event wait.
awaitReply :: EventRef request reply
  -> A.Agentic (ExceptT FetchError (Program calls)) request (ReceivedReply reply)
awaitReply (EventRef reference contracts) = case contracts of
  Left problem -> A.act (\_ -> throwE (FetchError (Text.pack (show problem))))
  Right (input,output) -> A.await
    (eventRequestCodec reference input.description output.description input.codec)
    (receivedReplyCodec output.codec)
