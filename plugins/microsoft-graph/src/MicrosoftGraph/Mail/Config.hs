{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Mail.Config (validate, login) where
import qualified Data.Text as Text
import Kyyn.Validation
import Kyyn.Plugin.Host (PluginLogin, LoginError)
import MicrosoftGraph.Mail.Types
import MicrosoftGraph.Config (authentication)
import qualified MicrosoftGraph.Auth as Auth

validate :: MailConfig -> ValidationReport
validate (MailConfig auth mailbox folders retention) = ValidationReport $
  authentication auth mailbox <>
  [errorDiagnostic "graph.mail-folders" "Choose at least one nonempty well-known folder or slash-separated folder path." |
    null folders || any invalid folders] <>
  [errorDiagnostic "graph.mail-retention" "retentionDays must be nonnegative." | retention < 0]
  where
    invalid (WellKnownFolder name) = Text.null name || Text.any (== '/') name
    invalid (FolderPath path) = any Text.null (Text.splitOn "/" path)

login :: MailConfig -> PluginLogin (Either LoginError ())
login (MailConfig auth _ _ _) = Auth.login auth
