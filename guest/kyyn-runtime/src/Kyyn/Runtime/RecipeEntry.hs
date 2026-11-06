{-# LANGUAGE RankNTypes, ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Runtime.RecipeEntry (recipeEntry) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Aeson as Json
import qualified Data.Aeson.Types as Json
import Agentic.Aeson (fromAeson)
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
  -> (RecipeInput root input state -> Program calls (Either FetchError (RecipeProposal edits state)))
  -> (DescriptionFormat -> Text) -> Either ProjectionError Entry
recipeEntry reference (metadata,sources) flowSources edits dispatch selected render = do
  root <- compileContract (contract @root)
  input <- compileContract (contract @input)
  state <- compileContract (contract @state)
  let contracts = RecipeContracts (describeContract root.description metadata sources)
        (describeContract input.description (SchemaMetadata [] [] []) flowSources)
        (describeContract state.description (SchemaMetadata [] [] []) flowSources)
      run transport value = do
        invocation <- either fail pure (Json.parseEither Json.parseJSON value)
        case invocation of
          RenderRecipe format -> writeReply transport (Json.String (render format))
          RunRecipe rootValue inputValue stateValue -> do
            decodedRoot <- decode root rootValue
            decodedInput <- decode input inputValue
            decodedState <- decode state stateValue
            execute transport (eitherCodec (recipeProposalCodec edits (runtimeCodec state.codec)))
              (dispatch transport) (selected (RecipeInput decodedRoot decodedInput decodedState))
  pure (Entry (RecipeEntry ("$recipe." <> reference) reference contracts) run)
  where
    decode compiled = either (fail . Text.unpack) pure . compiled.codec.decode . fromAeson
