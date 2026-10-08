{-# LANGUAGE OverloadedStrings #-}
module LocalFile.Folder (fetch) where

import Kyyn.Plugin
import qualified Data.Text as Text
import Kyyn.Plugin.Host
import qualified LocalFile.Types as Schema

-- | Return changes since the selected prior fetch. IDs are paths relative to the folder.
fetch :: Schema.FolderConfig -> EvidenceSnapshot Schema.Document
  -> Acquisition Schema.Document (Either FetchError [EvidenceChange Schema.Document])
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
                  current = [(EvidenceId (Text.pack path),Evidence token
                    [Text.pack resolved] (Available (Schema.Document text))) | (path,CapturedText text token resolved) <- zip paths texts]
                  changes = concatMap (changed old) current
                  removed = [RemovedEvidence key | key <- previousIds, key `notElem` map fst current]
              pure (changes ++ removed)
  where
    fullPath path = directory ++ "/" ++ path
    changed old (key,value) = case lookup key old of
      Nothing -> [NewEvidence key value]
      Just (Evidence token _ Truncated) | token == fingerprint value ->
        [SetEvidencePayload key token payload | Evidence _ _ payload <- [value]]
      Just previous | fingerprint previous == fingerprint value -> []
                    | otherwise -> [UpdatedEvidence key value]
    fingerprint (Evidence token _ _) = token

andThen :: Program calls (Either problem a) -> (a -> Program calls (Either problem b))
  -> Program calls (Either problem b)
andThen action next = action >>= either (pure . Left) next
