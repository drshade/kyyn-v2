{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Config (authentication) where

import qualified Data.Text as Text
import Data.Text (Text)
import Data.Char (isAsciiLower, isAsciiUpper, isSpace)
import Kyyn.Validation
import MicrosoftGraph.Types (GraphAuth(..))

authentication :: GraphAuth -> Text -> [Diagnostic]
authentication auth mailbox =
  [errorDiagnostic "graph.config" "Tenant, client ID, mailbox and secret key must be nonempty." |
    any Text.null [tenant,client,key,mailbox]] <>
  [errorDiagnostic "graph.secret-key" "Secret key must contain only ASCII letters, digits, hyphens or underscores." |
    Text.any (\c -> not (isAsciiLower c || isAsciiUpper c || c >= '0' && c <= '9' || c `elem` ("-_" :: String))) key] <>
  case auth of
    ClientSecret {} -> []
    DeviceCode _ _ _ scopes ->
      [errorDiagnostic "graph.scopes" "Delegated scopes must be nonempty individual scope names without whitespace." |
        null scopes || any (\s -> Text.null s || Text.any isSpace s) scopes]
  where
    (tenant,client,key) = case auth of ClientSecret t c k -> (t,c,k); DeviceCode t c k _ -> (t,c,k)
