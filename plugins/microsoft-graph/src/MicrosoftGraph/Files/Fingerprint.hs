module MicrosoftGraph.Files.Fingerprint (canonicalFile) where
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin (BlobRef(..))
import MicrosoftGraph.Files.Types (FilePayload(..))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text.Encoding as Encoding

canonicalFile :: FilePayload -> Text
canonicalFile (FilePayload name path url media size modified modifier tag (BlobRef hash bytes blobMedia blobName)) =
  render (Aeson.toJSON
    [string name, string path, string url, string media, integer size,
     string modified, string modifier, maybe Aeson.Null string tag,
     Aeson.toJSON [string hash, integer bytes, string blobMedia, maybe Aeson.Null string blobName]])
  where
    string = Aeson.String
    integer = string . Text.pack . show

render :: Aeson.Value -> Text
render = Encoding.decodeUtf8 . Lazy.toStrict . Aeson.encode
