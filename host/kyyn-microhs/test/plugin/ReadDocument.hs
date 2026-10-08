{-# LANGUAGE OverloadedStrings #-}
module ReadDocument (view) where

import Kyyn.Plugin
import Data.Text (Text)
import qualified Data.Text as Text
import qualified FolderSchema as Schema

view :: String -> EvidenceSnapshot Schema.Document -> CapturedRead Schema.Document (Either FetchError Text)
view identity snapshot = do
  result <- readEvidence snapshot (EvidenceId (Text.pack identity))
  pure $ case result of
    Left problem -> Left problem
    Right Nothing -> Left (FetchError "Document not found")
    Right (Just (Evidence _ _ (Available (Schema.Document text)))) -> Right text
    Right (Just (Evidence _ _ Truncated)) -> Left (FetchError "Payload truncated")
