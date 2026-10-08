{-# LANGUAGE OverloadedStrings #-}
module GitHub.Repository (fetch) where

import Control.Monad (forM, unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (sort, sortOn, groupBy)
import Data.Text (Text)
import qualified Data.Text as Text
import GitHub.Types (RepositoryConfig(RepositoryConfig), RepositoryItem(..), FileChange)
import qualified GitHub.Config as Config
import qualified GitHub.Decode as Decode
import qualified GitHub.Http as Http
import qualified GitHub.Json as Json
import GitHub.Fingerprint (canonicalItem)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import Kyyn.Validation (ValidationReport(..))
import Text.JSON.Types (JSValue)

fetch :: RepositoryConfig -> EvidenceSnapshot RepositoryItem
  -> Acquisition RepositoryItem (Either FetchError [EvidenceChange RepositoryItem])
fetch config@(RepositoryConfig url branch since secret) snapshot = fmap (either (Left . FetchError) Right) $ runExceptT $ do
  case Config.validate config of
    ValidationReport [] -> pure ()
    _ -> throwE "Invalid GitHub configuration; run the configuration validator"
  (owner,repo) <- checked (Config.repository url)
  token <- case secret of
    Nothing -> pure Nothing
    Just name -> do
      result <- ExceptT (Right <$> getSecret name)
      case result of
        Left _ -> throwE ("Missing GitHub token secret: " <> name)
        Right value | Text.null (Text.strip value) -> throwE "GitHub token is blank"
                    | otherwise -> pure (Just value)
  let base = "https://api.github.com/repos/" <> owner <> "/" <> repo <> "/"
      prefix = Text.toLower owner <> "/" <> Text.toLower repo <> "/"
      get path = ExceptT (Http.get base token (base <> path))
      pages path = ExceptT (Http.pages base token (base <> path))
      date = maybe "" (\value -> "&since=" <> Json.escape value) since
  oldIds <- ExceptT (fmap (either (\(FetchError message) -> Left message) Right) (listEvidenceIds snapshot))
  -- Open work remains visible even when it predates the requested history boundary.
  issues <- case since of
    Nothing -> pages "issues?state=all&sort=updated&direction=asc&per_page=100"
    Just _ -> do
      open <- pages "issues?state=open&sort=updated&direction=asc&per_page=100"
      closed <- pages ("issues?state=closed&sort=updated&direction=asc&per_page=100" <> date)
      pure (open ++ closed)
  numbered <- mapM (\value -> do n <- checked (Decode.numberField "number" value); pure (n,value)) issues
  discussions <- forM (unique numbered) $ \(number,value) -> do
    let suffix = Text.pack (show number)
    comments <- pages ("issues/" <> suffix <> "/comments?per_page=100") >>= checked . mapM Decode.comment
    issue <- checked (Decode.issue comments value)
    item <- if Json.has "pull_request" value then do
      (details,_) <- get ("pulls/" <> suffix)
      reviews <- pages ("pulls/" <> suffix <> "/reviews?per_page=100") >>= checked . mapM Decode.review
      PullRequestItem <$> checked (Decode.pullRequest issue reviews details)
      else pure (IssueItem issue)
    let key = prefix <> (if Json.has "pull_request" value then "pulls/" else "issues/") <> suffix
    ref <- checked (Decode.textField "html_url" value)
    pure (EvidenceId key,ref,item)
  commits <- pages ("commits?per_page=100" <> maybe "" (\value -> "&sha=" <> Json.escape value) branch <> date)
  commitKeys <- mapM (\value -> do sha <- checked (Decode.textField "sha" value); pure (prefix <> "commits/" <> sha,sha)) commits
  let unseen = without (sort [key | EvidenceId key <- oldIds]) (unique commitKeys)
  captured <- forM unseen $ \(key,sha) -> do
    let path = base <> "commits/" <> Json.escape sha <> "?per_page=100"
    (first,files) <- ExceptT (commitFiles base token [] path)
    actual <- checked (Decode.textField "sha" first)
    unless (actual == sha) (throwE "GitHub commit details do not match the requested SHA")
    item <- checked (Decode.commit files (length files < 3000) first)
    ref <- checked (Decode.textField "html_url" first)
    pure (EvidenceId key,ref,CommitItem item)
  let values = discussions ++ captured
  fingerprints <- ExceptT (Right <$> digestText [canonicalItem item | (_,_,item) <- values])
  unless (length fingerprints == length values) (throwE "Host returned the wrong number of GitHub fingerprints")
  changes <- forM (zip values fingerprints) $ \((key,ref,item),token) -> do
    previous <- ExceptT (fmap (either (\(FetchError message) -> Left message) Right) (readEvidence snapshot key))
    let fingerprint = EvidenceFingerprint token
        evidence = Evidence fingerprint [ref] (Available item)
    pure $ case previous of
      Nothing -> [NewEvidence key evidence]
      Just (Evidence prior _ availability)
        | prior /= fingerprint -> [UpdatedEvidence key evidence]
        | Truncated <- availability -> [SetEvidencePayload key fingerprint (Available item)]
        | otherwise -> []
  pure (concat changes)

checked :: Either Text a -> ExceptT Text (Acquisition RepositoryItem) a
checked = either throwE pure

-- Commit detail pages repeat commit metadata but paginate the changed-file list.
commitFiles :: Text -> Maybe Text -> [Text] -> Text
  -> Acquisition RepositoryItem (Either Text (JSValue,[FileChange]))
commitFiles base token seen url = runExceptT $ do
  if url `elem` seen then throwE "GitHub commit pagination repeated a page" else pure ()
  (value,next) <- ExceptT (Http.get base token url)
  files <- checked (Json.field "files" value >>= Json.array >>= mapM Decode.fileChange)
  rest <- case next of
    Nothing -> pure []
    Just link -> do
      (later,more) <- ExceptT (commitFiles base token (url:seen) link)
      firstSha <- checked (Decode.textField "sha" value)
      laterSha <- checked (Decode.textField "sha" later)
      unless (firstSha == laterSha) (throwE "GitHub commit changed identity between file-list pages")
      pure more
  pure (value,files ++ rest)

unique :: Ord a => [(a,b)] -> [(a,b)]
unique values = [last group | group <- groupBy (\a b -> fst a == fst b) (sortOn fst values), not (null group)]

without :: Ord a => [a] -> [(a,b)] -> [(a,b)]
without _ [] = []
without [] values = values
without old@(key:keys) values@((candidate,value):rest) = case compare key candidate of
  LT -> without keys values
  EQ -> without keys rest
  GT -> (candidate,value) : without old rest
