module Folder (fetch) where

import Kyyn.Plugin
import Kyyn.Plugin.Host
import qualified FolderSchema as Schema

fetch :: Schema.Config -> EvidenceSnapshot Schema.Document
  -> Acquisition Schema.Document (Either FetchError [EvidenceChange Schema.Document])
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
                    current = [(EvidenceId path,Evidence token
                      [fullPath path] (Schema.Document text)) | (path,CapturedText text token) <- zip paths texts]
                    changes = concatMap (changed old) current
                    removed = [RemovedEvidence key | key <- previousIds, key `notElem` map fst current]
                pure (changes ++ removed)
  where
    fullPath path = directory ++ "/" ++ path
    changed old (key,value) = case lookup key old of
      Nothing -> [NewEvidence key value]
      Just previous | fingerprint previous == fingerprint value -> []
                    | otherwise -> [UpdatedEvidence key value]
    fingerprint (Evidence token _ _) = token

andThen :: Program calls (Either problem a) -> (a -> Program calls (Either problem b))
  -> Program calls (Either problem b)
andThen action next = action >>= either (pure . Left) next
