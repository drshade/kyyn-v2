{-# LANGUAGE OverloadedStrings #-}
module Salesforce.Query (fetch) where
import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (sortOn)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import Kyyn.Validation
import Salesforce.Query.Types
import qualified Salesforce.Query.Config as Config
import qualified Salesforce.Query.Api as Api
import qualified Salesforce.Auth as Auth
import qualified Salesforce.Json as Json
import Text.JSON.Types (JSValue(..), toJSString)

fetch :: QueryConfig -> EvidenceSnapshot Record -> Acquisition Record (Either FetchError [EvidenceChange Record])
fetch config@(QueryConfig origin auth version query _) snapshot = fmap (either (Left . FetchError) Right) $ runExceptT $ do
  case Config.validate config of
    ValidationReport [] -> pure ()
    ValidationReport (Diagnostic _ _ message _:_) -> throwE message
  token <- ExceptT (Auth.accessToken origin auth)
  rows <- sortOn fst <$> ExceptT (Api.records token config)
  let reference = origin <> "/services/data/" <> version <> "/query?q=" <> Json.escape query
  inputs <- either throwE pure (mapM (\(_,Record _ body) -> Json.canonical (JSArray [JSString (toJSString reference),JSString (toJSString body)])) rows)
  digests <- ExceptT (Right <$> digestText inputs)
  if length digests /= length rows then throwE "Host returned the wrong number of Salesforce digests" else pure ()
  oldKeys <- ExceptT (fmap failure (listEvidenceIds snapshot))
  additions <- fmap concat $ forM (zip rows digests) $ \((key,record),digest) -> do
    old <- ExceptT (fmap failure (readEvidence snapshot (EvidenceId key)))
    let fingerprint = EvidenceFingerprint digest
        value = Evidence fingerprint [reference] (Available record)
    case old of
      Nothing -> pure [NewEvidence (EvidenceId key) value]
      Just (Evidence previous _ Truncated) | previous == fingerprint ->
        pure [SetEvidencePayload (EvidenceId key) fingerprint (Available record)]
      Just (Evidence previous _ _) | previous == fingerprint -> pure []
      _ -> pure [UpdatedEvidence (EvidenceId key) value]
  let keys = map (EvidenceId . fst) rows
  pure (additions ++ [RemovedEvidence key | key <- oldKeys, key `notElem` keys])
  where
    failure = either (\(FetchError message) -> Left message) Right
