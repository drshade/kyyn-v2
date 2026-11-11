module MicrosoftGraph.Directory.Fingerprint (canonicalDirectory) where
import Data.Text (Text)
import MicrosoftGraph.Directory.Types
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text.Encoding as Encoding

canonicalDirectory :: DirectoryPayload -> Text
canonicalDirectory (DirectoryPayload users) = render (Aeson.toJSON (map row users))
  where
    string = Aeson.String
    optional = maybe Aeson.Null string
    row (DirectoryUser key name given surname mail upn enabled kind) = Aeson.toJSON
      [string key, optional name, optional given, optional surname, optional mail, optional upn,
       maybe Aeson.Null Aeson.Bool enabled, optional kind]

render :: Aeson.Value -> Text
render = Encoding.decodeUtf8 . Lazy.toStrict . Aeson.encode
