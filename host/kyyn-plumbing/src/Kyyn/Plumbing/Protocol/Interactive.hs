{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
module Kyyn.Plumbing.Protocol.Interactive (parseProgress, parseFulfilment) where

import Control.Monad (unless)
import Data.Aeson (Value)
import qualified Data.Text as Text
import Data.Text (Text)
import Data.List (nub)
import Kyyn.Types.ChildWait (ChildWaitRequest(..), childWaitCodec)
import Kyyn.Types.EventWait (decodeEventRequest)
import Agentic.Codec (Codec(..))
import qualified Agentic.Value as V
import qualified Agentic.Wait as Wait
import qualified Agentic.Journal as Journal
import Agentic.Runtime (PendingWait(..))
import qualified Kyyn.Runtime.Json as Wire
import Kyyn.Runtime.ModelWire (valueCodec)
import Kyyn.Domain.FlowInstance (FlowProgress(..), DeliveryOutcome(..), WaitKind(..), flowInstanceId)

-- Preserve descriptors in their original tagged transport form. Upstream owns
-- their identity/key/schema validation and canonical durable-key text.
parseProgress :: Text -> Text -> Value -> Either String FlowProgress
parseProgress namespace revision value = do
  (tag,body) <- Wire.variant value
  case (tag,body) of
    ("finished",Just result) -> Right (FlowReturned result)
    ("waiting",Just encoded) -> do
      pending <- Wire.decodeWith (Wire.listCodec (Wire.Codec id Right)) encoded
      waits <- traverse descriptor pending
      unless (not (null waits) && length (nub ([identity | (identity,_,_) <- waits])) == length waits)
        (Left "Waiting frontier must contain distinct waits")
      pure (FlowWaiting waits)
    _ -> Left "Invalid interactive outcome"
  where
    descriptor encoded = do
      wire <- Wire.decodeWith valueCodec encoded
      pending <- either (Left . Text.unpack) Right (Wait.pendingWaitFromValue wire)
      unless (pending.identity == Journal.JournalIdentity namespace revision)
        (Left "Wait belongs to another instance or revision")
      kind <- case pending.request of
        V.Object fields | Just tag <- lookup "kyynWait" fields -> case tag of
          V.String "child" -> do
            ChildWaitRequest identity output <- either (Left . Text.unpack) Right (childWaitCodec.decode pending.request)
            ChildWait <$> flowInstanceId identity <*> pure output
          V.String "event" -> EventWait <$> either (Left . Text.unpack) Right (decodeEventRequest pending.request)
          _ -> Left "Unknown Kyyn wait envelope"
        _ -> Right ReplyWait
      pure (Journal.durableKeyText pending.key,encoded,kind)

parseFulfilment :: Value -> Either String DeliveryOutcome
parseFulfilment value = do
  (tag,body) <- Wire.variant value
  case (tag,body) of
    ("accepted",Nothing) -> Right Accepted
    ("refused",Just refusal) -> do
      (reason,message) <- Wire.variant refusal
      case (reason,message) of
        ("conflict",Nothing) -> Right Conflicting
        ("wrongIdentity",Nothing) -> Left "Stored wait belongs to another instance or revision"
        ("invalidKey",_) -> Left "Stored wait key is invalid"
        ("invalidRequest",_) -> Left "Stored wait request is invalid"
        ("invalid",Just text) -> Invalid <$> Wire.decodeWith Wire.textCodec text
        ("nonCanonical",Just text) -> Invalid <$> Wire.decodeWith Wire.textCodec text
        _ -> Left "Invalid fulfilment refusal"
    _ -> Left "Invalid fulfilment outcome"
