{-# LANGUAGE OverloadedStrings #-}
module Salesforce.Query.Read (record) where
import Data.Text (Text)
import Kyyn.Plugin
import Salesforce.Query.Types (Record)

record :: Text -> EvidenceSnapshot Record -> CapturedRead Record (Either FetchError Record)
record key snapshot = do
  found <- readEvidence snapshot (EvidenceId key)
  pure $ case found of
    Left problem -> Left problem
    Right Nothing -> Left (FetchError "No captured Salesforce record with that ID")
    Right (Just (Evidence _ _ Truncated)) -> Left (FetchError "Salesforce record payload is unavailable")
    Right (Just (Evidence _ _ (Available value))) -> Right value
