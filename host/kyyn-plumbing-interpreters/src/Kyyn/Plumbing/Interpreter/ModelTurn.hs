{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.ModelTurn
  ( runModelTurnIO, runModelTurnWithProvider, ConfiguredProvider(..) ) where

import qualified Agentic.OpenAI as OpenAI
import qualified Agentic.Anthropic as Anthropic
import Agentic.Runtime (SystemTwo(..), ProvidesSystemTwo(..))
import qualified Agentic.Settings as Settings
import Control.Exception (Handler(..), catches)
import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as Text
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Model
import Kyyn.Plumbing.Capability.ModelTurn
import Kyyn.Plumbing.Capability.SecretStore (SecretStore, readSecret)
import qualified Network.HTTP.Client as Http

-- No Show instance: these settings contain the resolved credential.
data ConfiguredProvider = ConfiguredOpenAI OpenAI.OpenAI | ConfiguredAnthropic Anthropic.Anthropic

runModelTurnIO :: (IOE :> es, SecretStore :> es) => Eff (ModelTurn : es) a -> Eff es a
runModelTurnIO = runModelTurnWithProvider $ \case
  ConfiguredOpenAI configuration -> toSystemTwo configuration
  ConfiguredAnthropic configuration -> toSystemTwo configuration

runModelTurnWithProvider :: (IOE :> es, SecretStore :> es)
  => (ConfiguredProvider -> IO (SystemTwo IO)) -> Eff (ModelTurn : es) a -> Eff es a
runModelTurnWithProvider connect = interpret $ \_ (TakeModelTurn (ModelConfiguration provider model secret) conversation) ->
  if null model || all isSpace model then pure (Left InvalidModelConfiguration) else do
    credential <- readSecret secret
    case credential of
      Left _ -> pure (Left (MissingModelSecret secret))
      Right key | Text.null key || Text.all isSpace key -> pure (Left (EmptyModelSecret secret))
      Right key -> liftIO $ (do
        SystemTwo turn <- connect (configured provider model key)
        Right <$> turn conversation) `catches`
          [ Handler (\(_ :: Http.HttpException) -> pure (Left ModelUnavailable))
          , Handler (pure . Left . openAIFailure)
          , Handler (pure . Left . anthropicFailure)
          ]

configured :: ModelProvider -> String -> Text -> ConfiguredProvider
configured OpenAI model key = ConfiguredOpenAI
  (Settings.key key (Settings.model (Text.pack model) OpenAI.openai))
configured Anthropic model key = ConfiguredAnthropic
  (Settings.key key (Settings.model (Text.pack model) Anthropic.anthropic))

httpFailure :: Int -> ModelFailure
httpFailure status
  | status == 401 || status == 403 = ModelAuthenticationRejected
  | status == 429 = ModelRateLimited
  | status >= 500 = ModelUnavailable
  | otherwise = ModelRequestRejected

openAIFailure :: OpenAI.OpenAIError -> ModelFailure
openAIFailure = \case
  OpenAI.MissingKey -> InvalidModelConfiguration
  OpenAI.HttpError status _ -> httpFailure status
  OpenAI.Refused _ -> ModelRefused
  OpenAI.Truncated -> ModelIncomplete
  OpenAI.Incomplete _ -> ModelIncomplete
  OpenAI.UnexpectedResponse _ -> InvalidModelResponse

anthropicFailure :: Anthropic.AnthropicError -> ModelFailure
anthropicFailure = \case
  Anthropic.MissingKey -> InvalidModelConfiguration
  Anthropic.HttpError status _ -> httpFailure status
  Anthropic.Refused _ -> ModelRefused
  Anthropic.Truncated -> ModelIncomplete
  Anthropic.UnexpectedStop _ -> ModelIncomplete
  Anthropic.UnexpectedResponse _ -> InvalidModelResponse
