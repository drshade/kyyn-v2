{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Config (validate, scope, window) where

import qualified Data.Text as Text
import Data.Text (Text)
import Data.Char (isAsciiLower, isAsciiUpper, isSpace)
import Kyyn.Validation
import MicrosoftGraph.Types
import MicrosoftGraph.Timestamp (timestamp)

validate :: CalendarConfig -> ValidationReport
validate config@(CalendarConfig auth mailbox _ _ _ _) = ValidationReport $
  [errorDiagnostic "graph.config" "Tenant, client ID, mailbox and secret key must be nonempty." |
    any Text.null [tenant,client,key,mailbox]] <>
  [errorDiagnostic "graph.secret-key" "Secret key must contain only ASCII letters, digits, hyphens or underscores." |
    Text.any (\c -> not (isAsciiLower c || isAsciiUpper c || c >= '0' && c <= '9' || c `elem` ("-_" :: String))) key] <>
  [errorDiagnostic "graph.calendar" message | Left message <- [window config]] <>
  case auth of
    ClientSecret {} -> []
    DeviceCode _ _ _ scopes ->
      [errorDiagnostic "graph.scopes" "Delegated scopes must be nonempty individual scope names without whitespace." |
        null scopes || any (\s -> Text.null s || Text.any isSpace s) scopes] <>
      [errorDiagnostic "graph.scopes" ("Calendar requires delegated scope " <> scope config <> "; include it in auth.scopes and run connector login.") |
        scope config `notElem` map qualify scopes]
  where
    (tenant,client,key) = case auth of ClientSecret t c k -> (t,c,k); DeviceCode t c k _ -> (t,c,k)
    qualify s | "https://graph.microsoft.com/" `Text.isPrefixOf` s = s
              | otherwise = "https://graph.microsoft.com/" <> s

scope :: CalendarConfig -> Text
scope (CalendarConfig _ _ _ shared _ _) = "https://graph.microsoft.com/Calendars.Read" <> if shared then ".Shared" else ""

window :: CalendarConfig -> Either Text (Text,Text)
window (CalendarConfig _ _ calendar _ start end) = do
  case calendar of
    Nothing -> pure ()
    Just _ -> Left "Calendar delta sync supports only the mailbox's default calendar; use calendarId = None Text."
  lower <- timestamp start
  upper <- timestamp end
  if lower < upper then Right (start,end) else Left "windowStart must be earlier than windowEnd."
