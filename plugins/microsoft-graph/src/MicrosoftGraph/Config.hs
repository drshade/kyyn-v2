{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Config (validate, scope) where

import qualified Data.Text as Text
import Data.Text (Text)
import Data.Char (isAsciiLower, isAsciiUpper)
import Kyyn.Validation
import MicrosoftGraph.Types

validate :: CalendarConfig -> ValidationReport
validate (CalendarConfig auth mailbox calendar _) = ValidationReport $
  [errorDiagnostic "graph.config" "Tenant, client ID, mailbox and secret key must be nonempty." |
    any Text.null [tenant,client,key,mailbox]] <>
  [errorDiagnostic "graph.secret-key" "Secret key must contain only ASCII letters, digits, hyphens or underscores." |
    Text.any (\c -> not (isAsciiLower c || isAsciiUpper c || c >= '0' && c <= '9' || c `elem` ("-_" :: String))) key] <>
  [errorDiagnostic "graph.calendar" "An explicit calendar ID must not be empty." | calendar == Just ""]
  where
    (tenant,client,key) = case auth of ClientSecret t c k -> (t,c,k); DeviceCode t c k -> (t,c,k)

scope :: CalendarConfig -> Text
scope (CalendarConfig _ _ _ shared) = "https://graph.microsoft.com/Calendars.Read" <> if shared then ".Shared" else ""
