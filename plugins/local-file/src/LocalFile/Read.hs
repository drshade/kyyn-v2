module LocalFile.Read (content) where

import Kyyn.Plugin
import LocalFile.Types (ContentId, Content, Document(..))

content :: ContentId -> EvidenceSnapshot Document -> CapturedRead Document (Either FetchError Content)
content key snapshot = do
  found <- readEvidence snapshot (EvidenceId key)
  pure $ case found of
    Left problem -> Left problem
    Right Nothing -> Left (FetchError ("No fetched file with evidence ID " ++ key))
    Right (Just (Evidence _ _ (Document text))) -> Right text
