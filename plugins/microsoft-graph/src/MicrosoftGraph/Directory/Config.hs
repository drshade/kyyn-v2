{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Directory.Config (validate, login) where
import qualified Data.Text as Text
import Kyyn.Validation
import Kyyn.Plugin.Host (PluginLogin, LoginError)
import MicrosoftGraph.Types (GraphAuth(..))
import MicrosoftGraph.Directory.Types (DirectoryConfig(..))
import MicrosoftGraph.Config (authentication, graphRoot)
import qualified MicrosoftGraph.Auth as Auth

validate :: DirectoryConfig -> ValidationReport
validate (DirectoryConfig auth) = ValidationReport $ authentication auth "directory" <> case auth of
  ClientSecret {} -> []
  DeviceCode _ _ _ scopes ->
    let normalized = map (\s -> let lower = Text.toLower s in maybe lower id (Text.stripPrefix graphRoot lower)) scopes
    in [errorDiagnostic "graph.directory-scopes" "Directory requires User.Read.All; consent and run login again after adding scopes." |
      not (any (`elem` normalized) ["user.read.all","user.readwrite.all","directory.read.all","directory.readwrite.all"])]

login :: DirectoryConfig -> PluginLogin (Either LoginError ())
login (DirectoryConfig auth) = Auth.login auth
