{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Files.Fingerprint (canonicalFile) where
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin (BlobRef(..))
import MicrosoftGraph.Files.Types (FilePayload(..))
import Text.JSON.Types (JSValue(..), toJSString)
import Text.JSON.String (showJSValue)

canonicalFile :: FilePayload -> Text
canonicalFile (FilePayload name path url media size modified modifier tag (BlobRef hash bytes blobMedia blobName)) =
  Text.pack (showJSValue (JSArray
    [string name, string path, string url, string media, integer size,
     string modified, string modifier, maybe JSNull string tag,
     JSArray [string hash, integer bytes, string blobMedia, maybe JSNull string blobName]]) "")
  where
    string = JSString . toJSString . Text.unpack
    integer = string . Text.pack . show
