module Options where

import KyynPluginBindings
import qualified FolderSchema as Schema

fetch :: Schema.Config -> Maybe Schema.FetchOptions -> EvidenceSnapshot Schema.Document
      -> Acquisition (Either FetchError [EvidenceChange Schema.Document])
fetch _ options _ = pure (Left (FetchError (case options of
  Nothing -> "default options"
  Just (Schema.FetchOptions label) -> label)))
