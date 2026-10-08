{-# LANGUAGE OverloadedStrings #-}
module GitHub.Fingerprint (canonicalItem) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.ByteString as Bytes
import GitHub.Types (RepositoryItem(..), Account(Account), Comment(Comment), Review(Review),
  Issue(Issue), PullRequest(PullRequest), Commit(Commit), CommitIdentity(CommitIdentity), FileChange(FileChange))

-- Length framing keeps arbitrary Markdown/text unambiguous, without depending on
-- compiler-specific derived Show or JSON object ordering.
frame :: [Text] -> Text
frame = Text.concat . map (\value -> Text.pack (show (Bytes.length (Text.encodeUtf8 value))) <> ":" <> value)
optional :: (a -> Text) -> Maybe a -> Text
optional _ Nothing = "none"
optional encode (Just value) = frame ["some",encode value]
number :: Integer -> Text
number = Text.pack . show
boolean :: Bool -> Text
boolean True = "true"
boolean False = "false"
account :: Account -> Text
account (Account login url) = frame [login,url]
comment :: Comment -> Text
comment (Comment id author body created updated url) = frame [number id,optional account author,body,created,updated,url]
review :: Review -> Text
review (Review id author body state submitted sha url) = frame [number id,optional account author,body,state,optional idText submitted,sha,url]
idText :: Text -> Text
idText value = value
issue :: Issue -> Text
issue (Issue id title body state reason author assignees labels milestone created updated closed url comments) = frame
  [number id,title,body,state,optional idText reason,optional account author,frame (map account assignees),frame labels,
   optional idText milestone,created,updated,optional idText closed,url,frame (map comment comments)]
pull :: PullRequest -> Text
pull (PullRequest discussion draft merged mergedAt baseBranch headBranch baseSha headSha mergeSha reviews) = frame
  [issue discussion,boolean draft,boolean merged,optional idText mergedAt,baseBranch,headBranch,baseSha,headSha,
   optional idText mergeSha,frame (map review reviews)]
identity :: CommitIdentity -> Text
identity (CommitIdentity name email timestamp) = frame [name,email,timestamp]
file :: FileChange -> Text
file (FileChange path status previous) = frame [path,status,optional idText previous]
commit :: Commit -> Text
commit (Commit sha message author committer parents url files complete) = frame
  [sha,message,optional identity author,optional identity committer,frame parents,url,frame (map file files),boolean complete]
canonicalItem :: RepositoryItem -> Text
canonicalItem (IssueItem value) = frame ["issue",issue value]
canonicalItem (PullRequestItem value) = frame ["pull",pull value]
canonicalItem (CommitItem value) = frame ["commit",commit value]
