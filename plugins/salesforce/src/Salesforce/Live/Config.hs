module Salesforce.Live.Config (validate, login) where

import Kyyn.Validation
import Kyyn.Plugin.Host
import Salesforce.Live.Types
import qualified Salesforce.Config as Shared
import qualified Salesforce.Auth as Auth

validate :: LiveConfig -> ValidationReport
validate (LiveConfig origin auth version) = ValidationReport $
  Shared.authentication origin auth ++ Shared.apiVersion version

login :: LiveConfig -> PluginLogin (Either LoginError ())
login (LiveConfig origin auth _) = Auth.login origin auth
