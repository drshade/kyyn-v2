{-# LANGUAGE OverloadedStrings #-}
module GitHub.Decode (issue, comment, review, pullRequest, commit, fileChange, textField, numberField) where

import Data.Text (Text)
import GitHub.Types
import qualified GitHub.Json as J
import Text.JSON.Types (JSValue)

textField key value = J.field key value >>= J.text
numberField key value = J.field key value >>= J.integer
list key parse value = J.field key value >>= J.array >>= mapM parse
body value = maybe "" id <$> J.optional "body" J.text value
account value = Account <$> textField "login" value <*> textField "html_url" value
comment :: JSValue -> Either Text Comment
comment value = Comment <$> numberField "id" value <*> J.optional "user" account value <*> body value
  <*> textField "created_at" value <*> textField "updated_at" value <*> textField "html_url" value
review :: JSValue -> Either Text Review
review value = Review <$> numberField "id" value <*> J.optional "user" account value <*> body value
  <*> textField "state" value <*> J.optional "submitted_at" J.text value <*> textField "commit_id" value <*> textField "html_url" value
issue :: [Comment] -> JSValue -> Either Text Issue
issue comments value = Issue <$> numberField "number" value <*> textField "title" value <*> body value
  <*> textField "state" value <*> J.optional "state_reason" J.text value <*> J.optional "user" account value
  <*> list "assignees" account value <*> list "labels" (textField "name") value
  <*> J.optional "milestone" (textField "title") value <*> textField "created_at" value
  <*> textField "updated_at" value <*> J.optional "closed_at" J.text value <*> textField "html_url" value <*> pure comments
pullRequest :: Issue -> [Review] -> JSValue -> Either Text PullRequest
pullRequest discussion reviews value = PullRequest discussion <$> (J.field "draft" value >>= J.boolean)
  <*> (J.field "merged" value >>= J.boolean) <*> J.optional "merged_at" J.text value
  <*> (J.field "base" value >>= textField "ref") <*> (J.field "head" value >>= textField "ref")
  <*> (J.field "base" value >>= textField "sha") <*> (J.field "head" value >>= textField "sha")
  <*> J.optional "merge_commit_sha" J.text value <*> pure reviews
fileChange :: JSValue -> Either Text FileChange
fileChange value = FileChange <$> textField "filename" value <*> textField "status" value
  <*> (if J.has "previous_filename" value then J.optional "previous_filename" J.text value else Right Nothing)
identity value = CommitIdentity <$> textField "name" value <*> textField "email" value <*> textField "date" value
commit :: [FileChange] -> Bool -> JSValue -> Either Text Commit
commit files complete value = do
  details <- J.field "commit" value
  Commit <$> textField "sha" value <*> textField "message" details
    <*> J.optional "author" identity details <*> J.optional "committer" identity details
    <*> list "parents" (textField "sha") value <*> textField "html_url" value <*> pure files <*> pure complete
