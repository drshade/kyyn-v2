module LocalFile.Folder (fetch) where

import KyynPluginBindings
import qualified LocalFile.Types as Schema

-- | Return changes since the selected prior fetch. IDs are paths relative to the folder.
fetch :: Schema.FolderConfig -> EvidenceSnapshot Schema.Document
  -> Acquisition (Either FetchError [EvidenceChange Schema.Document])
fetch (Schema.FolderConfig directory recursive) prior =
  listFiles directory recursive `andThen` \paths ->
    listEvidenceIds prior `andThen` \previousIds -> do
      previousResults <- mapM (readEvidence prior) previousIds
      case sequence previousResults of
        Left problem -> pure (Left problem)
        Right previous | any (== Nothing) previous -> pure (Left (FetchError "Prior evidence item is unavailable"))
                       | otherwise -> do
            contents <- mapM (readTextFile . fullPath) paths
            pure $ do
              texts <- sequence contents
              let old = [(key,value) | (key,Just value) <- zip previousIds previous]
                  current = [(EvidenceId path,Evidence [fullPath path] (Schema.Document text)) | (path,text) <- zip paths texts]
                  changes = concatMap (changed old) current
                  removed = [RemovedEvidence key | key <- previousIds, key `notElem` map fst current]
              pure (changes ++ removed)
  where
    fullPath path = directory ++ "/" ++ path
    changed old (key,value) = case lookup key old of
      Nothing -> [NewEvidence key value]
      Just previous | previous == value -> []
                    | otherwise -> [UpdatedEvidence key value]

andThen :: Program calls (Either problem a) -> (a -> Program calls (Either problem b))
  -> Program calls (Either problem b)
andThen action next = action >>= either (pure . Left) next
