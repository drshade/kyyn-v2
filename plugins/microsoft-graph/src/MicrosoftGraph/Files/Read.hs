{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Files.Read (file) where
import Data.Text (Text)
import Kyyn.Plugin
import MicrosoftGraph.Files.Types (FilePayload)

file :: Text -> EvidenceSnapshot FilePayload -> CapturedRead FilePayload (Either FetchError FilePayload)
file key snapshot = do
  found <- readEvidence snapshot (EvidenceId key)
  pure $ case found of
    Left problem -> Left problem
    Right Nothing -> Left (FetchError "No captured file with that ID")
    Right (Just (Evidence _ _ Truncated)) -> Left (FetchError "File payload has been truncated")
    Right (Just (Evidence _ _ (Available value))) -> Right value
