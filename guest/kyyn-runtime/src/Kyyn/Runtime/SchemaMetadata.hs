module Kyyn.Runtime.SchemaMetadata (encodeMetadata) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Types.SchemaMetadata (SchemaMetadata)

encodeMetadata :: SchemaMetadata -> Either String String
encodeMetadata = Right . Text.unpack . Text.decodeUtf8 . Lazy.toStrict . encode
