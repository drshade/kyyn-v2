module ReadDocument (view) where

import Kyyn.Plugin
import qualified FolderSchema as Schema

view :: String -> EvidenceSnapshot Schema.Document -> CapturedRead Schema.Document (Either FetchError String)
view identity snapshot = do
  result <- readEvidence snapshot (EvidenceId identity)
  pure $ case result of
    Left problem -> Left problem
    Right Nothing -> Left (FetchError "Document not found")
    Right (Just (Evidence _ _ (Schema.Document text))) -> Right text
