module MicrosoftGraph.Meetings.Fingerprint (artifactId, canonicalArtifact) where

import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin (BlobRef(..))
import MicrosoftGraph.Meetings.Types
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text.Encoding as Encoding

-- JSON arrays preserve boundaries even when provider identifiers contain separators.
artifactId :: Text -> Text -> Text -> Text
artifactId kind meetingId itemId = render (Aeson.toJSON (map string [kind,meetingId,itemId]))

canonicalArtifact :: MeetingArtifact -> Text
canonicalArtifact artifact = render $ case artifact of
  Transcript meeting created ended (BlobRef hash size media name) -> Aeson.toJSON
    [string "Transcript", ref meeting, string created, string ended,
      Aeson.toJSON [string hash, integer size, string media, optional string name]]
  Attendance meeting started ended attendees -> Aeson.toJSON
    [string "Attendance", ref meeting, string started, string ended, Aeson.toJSON (map record attendees)]
  where
    ref (MeetingRef key url subject organizer) = Aeson.toJSON (map string [key,url,subject,organizer])
    record (AttendanceRecord identity email role total intervals) = Aeson.toJSON
      [optional participant identity, optional string email, optional string role,
        optional integer total, Aeson.toJSON (map interval intervals)]
    participant (ParticipantIdentity key name tenant kind resource) = Aeson.toJSON
      (map (optional string) [key,name,tenant,kind,resource])
    interval (AttendanceInterval join leave duration) = Aeson.toJSON
      [optional string join, optional string leave, optional integer duration]

optional :: (a -> Aeson.Value) -> Maybe a -> Aeson.Value
optional f = maybe Aeson.Null f
string :: Text -> Aeson.Value
string = Aeson.String
integer :: Integer -> Aeson.Value
integer = string . Text.pack . show
render :: Aeson.Value -> Text
render = Encoding.decodeUtf8 . Lazy.toStrict . Aeson.encode
