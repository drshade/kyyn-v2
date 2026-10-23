{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Directory.Read (directory) where
import Data.Text (Text)
import Kyyn.Plugin
import MicrosoftGraph.Directory.Types (DirectoryPayload)

directory :: Text -> EvidenceSnapshot DirectoryPayload -> CapturedRead DirectoryPayload (Either FetchError DirectoryPayload)
directory key snapshot = do
  found <- readEvidence snapshot (EvidenceId key)
  pure $ case found of
    Left problem -> Left problem
    Right Nothing -> Left (FetchError "No captured directory with that ID")
    Right (Just (Evidence _ _ Truncated)) -> Left (FetchError "Directory payload has been truncated")
    Right (Just (Evidence _ _ (Available value))) -> Right value
