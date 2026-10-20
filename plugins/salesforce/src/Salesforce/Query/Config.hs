{-# LANGUAGE OverloadedStrings #-}
module Salesforce.Query.Config (validate, login) where
import Data.Char (isAsciiLower, isAsciiUpper, isSpace)
import qualified Data.Text as Text
import Kyyn.Validation
import Kyyn.Plugin.Host
import Salesforce.Query.Types
import qualified Salesforce.Config as Shared
import qualified Salesforce.Auth as Auth

validate :: QueryConfig -> ValidationReport
validate (QueryConfig origin auth version query field) = ValidationReport $
  Shared.authentication origin auth ++
  [errorDiagnostic "salesforce.version" "apiVersion must have the form v62.0 (choose a version enabled by your org)." | not (versionShape version)] ++
  [errorDiagnostic "salesforce.query" "query must be a SOQL SELECT." |
    case Text.words (Text.toLower query) of "select":_:_ -> False; _ -> True] ++
  [errorDiagnostic "salesforce.id-field" "idField must name a top-level field containing a nonempty string ID." |
    Text.null field || not (Text.all (\c -> isAsciiLower c || isAsciiUpper c || c >= '0' && c <= '9' || c == '_') field) || Text.any isSpace field]
  where
    versionShape v = case Text.stripPrefix "v" v of
      Just suffix -> case Text.splitOn "." suffix of
        [major,minor] -> all (\x -> not (Text.null x) && Text.all (\c -> c >= '0' && c <= '9') x) [major,minor]
        _ -> False
      Nothing -> False

login :: QueryConfig -> PluginLogin (Either LoginError ())
login (QueryConfig origin auth _ _ _) = Auth.login origin auth
