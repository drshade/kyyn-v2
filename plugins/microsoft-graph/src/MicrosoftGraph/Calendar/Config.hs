{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Calendar.Config (validate, login, window) where

import qualified Data.Text as Text
import Data.Text (Text)
import Kyyn.Validation
import Kyyn.Plugin.Host (PluginLogin, LoginError)
import MicrosoftGraph.Types (GraphAuth(..))
import MicrosoftGraph.Calendar.Types (CalendarConfig(..))
import MicrosoftGraph.Config (authentication)
import qualified MicrosoftGraph.Auth as Auth
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

window :: CalendarConfig -> Either Text (Text,Text)
window (CalendarConfig _ _ calendar _ start end) = do
  case calendar of
    Nothing -> pure ()
    Just _ -> Left "Calendar delta sync supports only the mailbox's default calendar; use calendarId = None Text."
  lower <- timestamp start
  upper <- timestamp end
  if lower < upper then Right (start,end) else Left "windowStart must be earlier than windowEnd."

login :: CalendarConfig -> PluginLogin (Either LoginError ())
login (CalendarConfig auth _ _ _ _ _) = Auth.login auth
