module MicrosoftGraph.Mail.Fingerprint (canonicalMessage) where

import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin (BlobRef(..))
import MicrosoftGraph.Mail.Types
import MicrosoftGraph.Types (Person(..))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text.Encoding as Encoding

-- Explicit field order and JSON escaping give both guest compilers the same
-- representation. Derived Show is a debugging format, not a content encoding.
canonicalMessage :: Message -> Text
canonicalMessage (Message subject sender recipients copies sent received conversation internetId folder body attachments) =
  render (Aeson.toJSON
    [ string subject, person sender, Aeson.toJSON (map person recipients), Aeson.toJSON (map person copies)
    , string sent, string received, string conversation, string internetId, string folder
    , string body, Aeson.toJSON (map attachment attachments) ])
  where
    person (Person name address) = Aeson.toJSON [string name, string address]
    attachment (Attachment name media size inline content) = Aeson.toJSON
      [string name, string media, integer size, Aeson.Bool inline, contents content]
    contents (Link uri) = Aeson.toJSON [string "Link", string uri]
    contents (Stored (BlobRef hash size media name)) = Aeson.toJSON
      [string "Stored", string hash, integer size, string media, maybe Aeson.Null string name]

string :: Text -> Aeson.Value
string = Aeson.String

integer :: Integer -> Aeson.Value
integer = string . Text.pack . show

render :: Aeson.Value -> Text
render = Encoding.decodeUtf8 . Lazy.toStrict . Aeson.encode
