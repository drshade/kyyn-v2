{-# LANGUAGE OverloadedStrings #-}
module Salesforce.Config (origin, authentication, tokenEndpoint) where
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import Salesforce.Types
import Kyyn.Validation

origin :: Text -> Bool
origin url = case Text.stripPrefix "https://" url of
  Nothing -> False
  Just host -> Text.any (== '.') host && all label (Text.splitOn "." host)
  where
    label x = not (Text.null x) && Text.head x /= '-' && Text.last x /= '-'
      && Text.all (\c -> ascii c || c == '-') x
    ascii c = isAsciiLower c || isAsciiUpper c || c >= '0' && c <= '9'

tokenEndpoint :: Text -> Text
tokenEndpoint url = url <> "/services/oauth2/token"

authentication :: Text -> SalesforceAuth -> [Diagnostic]
authentication url auth =
  [errorDiagnostic "salesforce.origin" "instanceUrl must be an exact HTTPS My Domain origin, without path, query or trailing slash." | not (origin url)] ++
  [errorDiagnostic "salesforce.client" "clientId must not be blank." | Text.null (Text.strip client)] ++
  [errorDiagnostic "salesforce.secret" "Secret key must contain ASCII letters, digits, hyphens or underscores." |
    Text.null key || Text.any (\c -> not (isAsciiLower c || isAsciiUpper c || isDigit c && c <= '9' || c `elem` ("-_" :: String))) key]
  where
    (client,key) = case auth of ClientSecret c k -> (c,k); DeviceCode c k -> (c,k)
