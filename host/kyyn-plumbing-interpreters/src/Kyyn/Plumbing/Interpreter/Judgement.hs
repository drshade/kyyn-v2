{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.Judgement (runJudgementIO, runJudgementWithProvider) where

import qualified Agentic.Jev as Jev
import Agentic.Runtime (SystemOne(..), ProvidesSystemOne(..))
import qualified Agentic.Settings as Settings
import Control.Exception (Handler(..), catches)
import qualified Data.Text as Text
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Model
import Kyyn.Domain.Secret (secretName)
import Kyyn.Plumbing.Capability.Judgement
import Kyyn.Plumbing.Capability.SecretStore (SecretStore, readSecret)
import qualified Network.HTTP.Client as Http

runJudgementIO :: (IOE :> es, SecretStore :> es) => Eff (Judgement : es) a -> Eff es a
runJudgementIO = runJudgementWithProvider toSystemOne

runJudgementWithProvider :: (IOE :> es, SecretStore :> es)
  => (Jev.Jev -> IO (SystemOne IO)) -> Eff (Judgement : es) a -> Eff es a
runJudgementWithProvider connect = interpret $ \_ (Judge question) -> do
  let name = either error id (secretName "JEV_TOKEN")
  credential <- readSecret name
  case credential of
    Left _ -> pure (Left (MissingModelSecret name))
    Right key | Text.null (Text.strip key) -> pure (Left (EmptyModelSecret name))
    Right key -> liftIO $ (do
      SystemOne ask <- connect (Settings.key key (Settings.model "jev-1.13.0" Jev.jev))
      Right <$> ask question) `catches`
        [ Handler (\(_ :: Http.HttpException) -> pure (Left ModelUnavailable))
        , Handler (pure . Left . providerFailure) ]

providerFailure :: Jev.JevError -> ModelFailure
providerFailure = \case
  Jev.MissingKey -> InvalidModelConfiguration
  Jev.UnexpectedResponse _ -> InvalidModelResponse
  Jev.HttpError status _
    | status == 401 || status == 403 -> ModelAuthenticationRejected
    | status == 429 -> ModelRateLimited
    | status >= 500 -> ModelUnavailable
    | otherwise -> ModelRequestRejected
