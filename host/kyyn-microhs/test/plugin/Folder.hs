module Folder (fetch) where

import KyynPluginBindings hiding (fetch)
import qualified FolderSchema as Schema

fetch :: Schema.Config -> EvidenceSnapshot Schema.Document
  -> Acquisition (Either FetchError [EvidenceChange Schema.Document])
fetch (Schema.Config directory recursive) prior
  | null directory || head directory /= '/' = pure (Left (FetchError "Folder directory must be absolute"))
  | otherwise = listFiles directory recursive `andThen` \paths ->
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
