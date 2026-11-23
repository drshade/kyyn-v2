{-# LANGUAGE RankNTypes, ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Runtime.InteractiveEntry (interactiveEntry) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Aeson as Json
import qualified Data.Aeson.Types as Json
import Agentic.Aeson (fromAeson)
import qualified Agentic as A
import qualified Agentic.Describe as Flow
import Agentic.Runtime (FlowError)
import qualified Agentic.Journal as J
import qualified Agentic.Wait as Wait
import qualified Data.List.NonEmpty as NonEmpty
import Control.Monad.Trans.Except (ExceptT, runExceptT)
import Kyyn.Contract
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Types.Plugin (FetchError)
import Kyyn.Types.Program (Program)
import Kyyn.Types.FlowJournal (JournalRequest)
import Kyyn.Runtime.FlowJournal (guestJournal)
import Kyyn.Runtime.Contract (runtimeCodec)
import Kyyn.Runtime.Entry (Entry(..), writeReply)
import Kyyn.Runtime.Transport (Transport)
import Kyyn.Runtime.Plugin (execute, eitherCodec)
import Kyyn.Runtime.ModelWire (valueCodec)
import qualified Kyyn.Runtime.Json as Wire

-- Interactive entries have their own request/result types. They do not receive
-- shared recipe state, and returning a result does not create or accept a proposal.
interactiveEntry :: forall input output calls. (Contract input, Contract output)
  => Text -> [Text]
  -> (forall a. Transport -> Integer -> calls a -> IO a)
  -> A.Runtime (ExceptT FetchError (Program calls))
  -> (forall a. JournalRequest a -> calls a)
  -> A.Agentic (ExceptT FetchError (Program calls)) input output
  -> Either FlowError Flow.Description -> Either ProjectionError Entry
interactiveEntry reference sources dispatch runtime inject selected description = do
  input <- compileContract (contract @input)
  output <- compileContract (contract @output)
  let describe compiled = describeContract compiled.description (SchemaMetadata [] [] []) sources
      contracts = InteractiveContracts (describe input) (describe output)
      run transport value = do
        invocation <- either fail pure (Json.parseEither Json.parseJSON value)
        case invocation of
          RenderFlow format -> do
            described <- either (fail . show) pure description
            let render = case format of Tree -> Flow.renderTree; Dot -> Flow.dot; Mermaid -> Flow.mermaid
            writeReply transport (Json.String (render described))
          CaptureFlowGraph -> do
            described <- either (fail . show) pure description
            writeReply transport (Json.object ["graph" Json..= Wire.encodeWith valueCodec (Flow.flowGraphValue (Flow.flowGraph described)),
              "mermaid" Json..= Flow.mermaid described])
          ResumeFlow namespace revision inputValue -> do
            decoded <- either (fail . Text.unpack) pure (input.codec.decode (fromAeson inputValue))
            let durable = runtime { A.journal = Just (guestJournal inject (J.JournalIdentity namespace revision)) }
            execute transport (eitherCodec (progressCodec (runtimeCodec output.codec)))
              (dispatch transport) (runExceptT (A.resumable durable selected decoded))
          FulfilFlow namespace revision pendingValue replyValue -> do
            pendingWire <- either fail pure (Wire.decodeWith valueCodec pendingValue)
            pending <- either (fail . Text.unpack) pure (Wait.pendingWaitFromValue pendingWire)
            reply <- either fail pure (Wire.decodeWith valueCodec replyValue)
            let durable = runtime { A.journal = Just (guestJournal inject (J.JournalIdentity namespace revision)) }
            execute transport (eitherCodec fulfilCodec) (dispatch transport)
              (runExceptT (A.fulfil durable selected pending reply))
  pure (Entry (InteractiveEntry ("$interactive." <> reference) reference contracts) run)

progressCodec :: Wire.Codec a -> Wire.Codec (A.Progress a)
progressCodec result = Wire.Codec encode decode
  where
    encode (A.RunFinished value) = Wire.tagged "finished" (Just (Wire.encodeWith result value))
    encode (A.RunWaiting waits) = Wire.tagged "waiting" (Just (Wire.encodeWith (Wire.listCodec valueCodec)
      (map Wait.pendingWaitValue (NonEmpty.toList waits))))
    decode value = do
      (tag,payload) <- Wire.variant value
      case (tag,payload) of
        ("finished",Just body) -> A.RunFinished <$> Wire.decodeWith result body
        ("waiting",Just body) -> do
          values <- Wire.decodeWith (Wire.listCodec valueCodec) body
          waits <- traverse (either (Left . Text.unpack) Right . Wait.pendingWaitFromValue) values
          maybe (Left "Empty waiting frontier") (Right . A.RunWaiting) (NonEmpty.nonEmpty waits)
        _ -> Left "Invalid interactive outcome"

fulfilCodec :: Wire.Codec (Either A.ReplyRefused ())
fulfilCodec = Wire.Codec
  (either (\refusal -> Wire.tagged "refused" (Just (encodeRefusal refusal)))
          (const (Wire.tagged "accepted" Nothing)))
  (\value -> do
    (tag,payload) <- Wire.variant value
    case (tag,payload) of
      ("accepted",Nothing) -> Right (Right ())
      ("refused",Just body) -> Left <$> decodeRefusal body
      _ -> Left "Invalid fulfilment outcome")
  where
    encodeRefusal refusal = case refusal of
      A.ReplyInvalid message -> text "invalid" message
      A.ReplyAlreadyAnswered -> Wire.tagged "conflict" Nothing
      A.ReplyNonCanonical message -> text "nonCanonical" message
      A.WaitWrongIdentity -> Wire.tagged "wrongIdentity" Nothing
      A.WaitInvalidKey message -> text "invalidKey" message
      A.WaitInvalidRequest message -> text "invalidRequest" message
    text code = Wire.tagged code . Just . Wire.encodeWith Wire.textCodec
    decodeRefusal value = do
      (tag,payload) <- Wire.variant value
      case (tag,payload) of
        ("invalid",Just body) -> A.ReplyInvalid <$> Wire.decodeWith Wire.textCodec body
        ("conflict",Nothing) -> Right A.ReplyAlreadyAnswered
        ("nonCanonical",Just body) -> A.ReplyNonCanonical <$> Wire.decodeWith Wire.textCodec body
        ("wrongIdentity",Nothing) -> Right A.WaitWrongIdentity
        ("invalidKey",Just body) -> A.WaitInvalidKey <$> Wire.decodeWith Wire.textCodec body
        ("invalidRequest",Just body) -> A.WaitInvalidRequest <$> Wire.decodeWith Wire.textCodec body
        _ -> Left "Invalid reply refusal"
