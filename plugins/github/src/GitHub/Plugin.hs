{-# LANGUAGE OverloadedStrings #-}
module GitHub.Plugin (connectors) where
import Kyyn.Plugin

connectors :: [SourceConnector]
connectors = [SourceConnector
  { name = "Repository", fetch = "GitHub.Repository.fetch"
  , validateConfig = "GitHub.Config.validate", login = Nothing
  , methods =
      [ CapturedMethod "item" "Read a captured issue, PR or commit by evidence ID." "GitHub.Read.item"
      , CapturedMethod "issue" "Read an issue including its conversation." "GitHub.Read.issue"
      , CapturedMethod "pullRequest" "Read a PR including conversation and review summaries." "GitHub.Read.pullRequest"
      , CapturedMethod "commit" "Read commit metadata and changed paths; no source or patches." "GitHub.Read.commit"
      ]
  }]
