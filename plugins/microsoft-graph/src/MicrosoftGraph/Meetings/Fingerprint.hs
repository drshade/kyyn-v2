{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Meetings.Fingerprint (artifactId, canonicalArtifact) where

import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin (BlobRef(..))
import MicrosoftGraph.Meetings.Types
import Text.JSON.Types (JSValue(..), toJSString)
import Text.JSON.String (showJSValue)

-- JSON arrays preserve boundaries even when provider identifiers contain separators.
artifactId :: Text -> Text -> Text -> Text
artifactId kind meetingId itemId = render (JSArray (map string [kind,meetingId,itemId]))

canonicalArtifact :: MeetingArtifact -> Text
canonicalArtifact artifact = render $ case artifact of
  Transcript meeting created ended (BlobRef hash size media name) -> JSArray
    [string "Transcript", ref meeting, string created, string ended,
      JSArray [string hash, integer size, string media, optional string name]]
  Attendance meeting started ended attendees -> JSArray
    [string "Attendance", ref meeting, string started, string ended, JSArray (map record attendees)]
  where
    ref (MeetingRef key url subject organizer) = JSArray (map string [key,url,subject,organizer])
    record (AttendanceRecord identity email role total intervals) = JSArray
      [optional participant identity, optional string email, optional string role,
        optional integer total, JSArray (map interval intervals)]
    participant (ParticipantIdentity key name tenant kind resource) = JSArray
      (map (optional string) [key,name,tenant,kind,resource])
    interval (AttendanceInterval join leave duration) = JSArray
      [optional string join, optional string leave, optional integer duration]

optional :: (a -> JSValue) -> Maybe a -> JSValue
optional f = maybe JSNull f
string :: Text -> JSValue
string = JSString . toJSString . Text.unpack
integer :: Integer -> JSValue
integer = string . Text.pack . show
render :: JSValue -> Text
render value = Text.pack (showJSValue value "")
