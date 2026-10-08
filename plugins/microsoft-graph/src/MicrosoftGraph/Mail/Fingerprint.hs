{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Mail.Fingerprint (canonicalMessage) where

import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin (BlobRef(..))
import MicrosoftGraph.Mail.Types
import MicrosoftGraph.Types (Person(..))
import Text.JSON.Types (JSValue(..), toJSString)
import Text.JSON.String (showJSValue)

-- Explicit field order and JSON escaping give both guest compilers the same
-- representation. Derived Show is a debugging format, not a content encoding.
canonicalMessage :: Message -> Text
canonicalMessage (Message subject sender recipients copies sent received conversation internetId folder body attachments) =
  Text.pack (showJSValue (JSArray
    [ string subject, person sender, JSArray (map person recipients), JSArray (map person copies)
    , string sent, string received, string conversation, string internetId, string folder
    , string body, JSArray (map attachment attachments) ]) "")
  where
    person (Person name address) = JSArray [string name, string address]
    attachment (Attachment name media size inline content) = JSArray
      [string name, string media, integer size, JSBool inline, contents content]
    contents (Link uri) = JSArray [string "Link", string uri]
    contents (Stored (BlobRef hash size media name)) = JSArray
      [string "Stored", string hash, integer size, string media, maybe JSNull string name]

string :: Text -> JSValue
string = JSString . toJSString . Text.unpack

integer :: Integer -> JSValue
integer = string . Text.pack . show
