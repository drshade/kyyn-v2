{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Meetings.Config (validate, login) where

import qualified Data.Text as Text
import Kyyn.Validation
import Kyyn.Plugin.Host (PluginLogin, LoginError)
import MicrosoftGraph.Types (GraphAuth(..))
import MicrosoftGraph.Meetings.Types (MeetingsConfig(..))
import MicrosoftGraph.Config (authentication, graphRoot)
import qualified MicrosoftGraph.Auth as Auth

validate :: MeetingsConfig -> ValidationReport
validate (MeetingsConfig auth user retention) = ValidationReport $
  authentication auth user <>
  [errorDiagnostic "graph.meetings-retention" "retentionDays must be nonnegative." | retention < 0] <>
  case auth of
    ClientSecret {} -> []
    DeviceCode _ _ _ scopes ->
      let normalized = map (\s -> let lower = Text.toLower s in maybe lower id (Text.stripPrefix graphRoot lower)) scopes
          required = [["user.read","user.readwrite"], ["calendars.read","calendars.readwrite"],
            ["onlinemeetings.read","onlinemeetings.readwrite"], ["onlinemeetingtranscript.read.all"], ["onlinemeetingartifact.read.all"]]
      in [errorDiagnostic "graph.meetings-scopes" "Meetings requires User.Read, Calendars.Read, OnlineMeetings.Read, OnlineMeetingTranscript.Read.All and OnlineMeetingArtifact.Read.All; consent and run login again after adding scopes." |
            any (not . any (`elem` normalized)) required]

login :: MeetingsConfig -> PluginLogin (Either LoginError ())
login (MeetingsConfig auth _ _) = Auth.login auth
