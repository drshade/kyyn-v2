{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Directory.Fingerprint (canonicalDirectory) where
import Data.Text (Text)
import qualified Data.Text as Text
import MicrosoftGraph.Directory.Types
import Text.JSON.Types (JSValue(..), toJSString)
import Text.JSON.String (showJSValue)

canonicalDirectory :: DirectoryPayload -> Text
canonicalDirectory (DirectoryPayload users) = Text.pack (showJSValue (JSArray (map row users)) "")
  where
    string = JSString . toJSString . Text.unpack
    optional = maybe JSNull string
    row (DirectoryUser key name given surname mail upn enabled kind) = JSArray
      [string key, optional name, optional given, optional surname, optional mail, optional upn,
       maybe JSNull JSBool enabled, optional kind]
