{-# LANGUAGE RankNTypes, ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Runtime.RecipeEntry (recipeEntry) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Aeson as Json
import qualified Data.Aeson.Types as Json
import Agentic.Aeson (fromAeson)
import Kyyn.Runtime.ModelWire (valueCodec)
import qualified Agentic.Describe as Flow
import Agentic.Runtime (FlowError)
import qualified Agentic as A
import qualified Agentic.Journal as J
import qualified Agentic.Wait as Wait
import qualified Data.List.NonEmpty as NonEmpty
import Control.Monad.Trans.Except (ExceptT, runExceptT)
import Kyyn.Types.FlowJournal (JournalRequest)
import Kyyn.Runtime.FlowJournal (guestJournal)
import Kyyn.Contract
import Kyyn.Recipe (RecipeInput(..), RecipeProposal)
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Types.Plugin (FetchError)
import Kyyn.Types.Program (Program)
import Kyyn.Runtime.Contract (runtimeCodec)
import Kyyn.Runtime.Entry (Entry(..), writeReply)
import Kyyn.Runtime.Transport (Transport)
import Kyyn.Runtime.Plugin (execute, eitherCodec)
import Kyyn.Runtime.Proposal (recipeProposalCodec)
import qualified Kyyn.Runtime.Json as Wire

recipeEntry :: forall root input state edits calls. (Contract root, Contract input, Contract state)
  => Text -> (SchemaMetadata,[Text]) -> [Text] -> Wire.Codec edits
  -> (forall a. Transport -> Integer -> calls a -> IO a)
  -> A.Runtime (ExceptT FetchError (Program calls))
  -> (forall a. JournalRequest a -> calls a)
  -> A.Agentic (ExceptT FetchError (Program calls)) (RecipeInput root input state) (RecipeProposal edits state)
  -> Either FlowError Flow.Description -> Either ProjectionError Entry
recipeEntry reference (metadata,sources) flowSources edits dispatch runtime inject selected description = do
  root <- compileContract (contract @root)
  input <- compileContract (contract @input)
  state <- compileContract (contract @state)
  let contracts = RecipeContracts (describeContract root.description metadata sources)
        (describeContract input.description (SchemaMetadata [] [] []) flowSources)
        (describeContract state.description (SchemaMetadata [] [] []) flowSources)
      run transport value = do
        invocation <- either fail pure (Json.parseEither Json.parseJSON value)
        case invocation of
          RenderRecipe format -> do
            described <- either (fail . show) pure description
            let render = case format of Tree -> Flow.renderTree; Dot -> Flow.dot; Mermaid -> Flow.mermaid
            writeReply transport (Json.String (render described))
          CaptureRecipeGraph -> do
            described <- either (fail . show) pure description
            writeReply transport (Json.object ["graph" Json..= Wire.encodeWith valueCodec (Flow.flowGraphValue (Flow.flowGraph described)),
              "mermaid" Json..= Flow.mermaid described])
          RunRecipe rootValue inputValue stateValue -> do
            decodedRoot <- decode root rootValue
            decodedInput <- decode input inputValue
            decodedState <- decode state stateValue
            execute transport (eitherCodec (recipeProposalCodec edits (runtimeCodec state.codec)))
              (dispatch transport) (runExceptT (A.interpret runtime selected (RecipeInput decodedRoot decodedInput decodedState)))
          ResumeRecipe namespace revision rootValue inputValue stateValue -> do
            decodedRoot <- decode root rootValue
            decodedInput <- decode input inputValue
            decodedState <- decode state stateValue
            let durable = runtime { A.journal = Just (guestJournal inject (J.JournalIdentity namespace revision)) }
            execute transport (eitherCodec (progressCodec (recipeProposalCodec edits (runtimeCodec state.codec))))
              (dispatch transport) (runExceptT (A.resumable durable selected (RecipeInput decodedRoot decodedInput decodedState)))
          FulfilRecipe namespace revision pendingValue replyValue -> do
            pendingWire <- either fail pure (Wire.decodeWith valueCodec pendingValue)
            pending <- either (fail . Text.unpack) pure (Wait.pendingWaitFromValue pendingWire)
            reply <- either fail pure (Wire.decodeWith valueCodec replyValue)
            let durable = runtime { A.journal = Just (guestJournal inject (J.JournalIdentity namespace revision)) }
                result = fmap (either (Left . show) (const (Right ()))) (A.fulfil durable selected pending reply)
            execute transport (eitherCodec fulfilCodec) (dispatch transport) (runExceptT result)
  pure (Entry (RecipeEntry ("$recipe." <> reference) reference contracts) run)
  where
    decode compiled = either (fail . Text.unpack) pure . compiled.codec.decode . fromAeson

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

fulfilCodec :: Wire.Codec (Either String ())
fulfilCodec = Wire.Codec
  (either (\message -> Wire.tagged "refused" (Just (Wire.encodeWith Wire.stringCodec message)))
          (const (Wire.tagged "accepted" Nothing)))
  (\value -> do
    (tag,payload) <- Wire.variant value
    case (tag,payload) of
      ("accepted",Nothing) -> Right (Right ())
      ("refused",Just body) -> Left <$> Wire.decodeWith Wire.stringCodec body
      _ -> Left "Invalid fulfilment outcome")
