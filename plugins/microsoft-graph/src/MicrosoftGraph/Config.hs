{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Config (validate, authentication, window) where

import qualified Data.Text as Text
import Data.Text (Text)
import Data.Char (isAsciiLower, isAsciiUpper, isSpace)
import Kyyn.Validation
import MicrosoftGraph.Types
import MicrosoftGraph.Timestamp (timestamp)

validate :: CalendarConfig -> ValidationReport
validate config@(CalendarConfig auth mailbox _ _ _ _) = ValidationReport $
  authentication auth mailbox <>
  [errorDiagnostic "graph.calendar" message | Left message <- [window config]] <>
  case auth of
    ClientSecret {} -> []
    DeviceCode _ _ _ scopes ->
      [errorDiagnostic "graph.scopes" "Shared calendar access requires Calendars.Read.Shared or Calendars.ReadWrite.Shared in auth.scopes; run connector login after changing scopes." |
        sharedCalendar config && not (any (`elem` ["calendars.read.shared","calendars.readwrite.shared"]) (map normalize scopes))]
  where
    normalize s = let lower = Text.toLower s
      in maybe lower id (Text.stripPrefix "https://graph.microsoft.com/" lower)

authentication :: GraphAuth -> Text -> [Diagnostic]
authentication auth mailbox =
  [errorDiagnostic "graph.config" "Tenant, client ID, mailbox and secret key must be nonempty." |
    any Text.null [tenant,client,key,mailbox]] <>
  [errorDiagnostic "graph.secret-key" "Secret key must contain only ASCII letters, digits, hyphens or underscores." |
    Text.any (\c -> not (isAsciiLower c || isAsciiUpper c || c >= '0' && c <= '9' || c `elem` ("-_" :: String))) key] <>
  case auth of
    ClientSecret {} -> []
    DeviceCode _ _ _ scopes ->
      [errorDiagnostic "graph.scopes" "Delegated scopes must be nonempty individual scope names without whitespace." |
        null scopes || any (\s -> Text.null s || Text.any isSpace s) scopes]
  where
    (tenant,client,key) = case auth of ClientSecret t c k -> (t,c,k); DeviceCode t c k _ -> (t,c,k)

window :: CalendarConfig -> Either Text (Text,Text)
window (CalendarConfig _ _ calendar _ start end) = do
  case calendar of
    Nothing -> pure ()
    Just _ -> Left "Calendar delta sync supports only the mailbox's default calendar; use calendarId = None Text."
  lower <- timestamp start
  upper <- timestamp end
  if lower < upper then Right (start,end) else Left "windowStart must be earlier than windowEnd."
