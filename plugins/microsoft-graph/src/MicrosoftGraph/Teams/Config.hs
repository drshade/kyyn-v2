module MicrosoftGraph.Teams.Config (validate, check, login) where

import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Validation
import Kyyn.Plugin.Host (PluginLogin, LoginError(..))
import MicrosoftGraph.Types (GraphAuth(..))
import MicrosoftGraph.Teams.Types (TeamsConfig(..))
import MicrosoftGraph.Config (authentication, graphRoot)
import qualified MicrosoftGraph.Auth as Auth
import qualified MicrosoftGraph.Teams.Auth as TeamsAuth

validate :: TeamsConfig -> ValidationReport
validate config = ValidationReport [errorDiagnostic "graph.teams" message | Left message <- [check config]]

check :: TeamsConfig -> Either Text ()
check (TeamsConfig auth chat respondent) = do
  if null (authentication auth chat) && not (Text.null (Text.strip respondent)) && not (Text.null (Text.strip chat))
    then pure () else Left "Teams requires tenant, client ID, secret key, chat ID and respondent ID."
  case auth of
    ClientSecret {} -> Left "Teams questions require delegated DeviceCode authentication; application credentials cannot send ordinary chat questions."
    DeviceCode _ _ _ scopes ->
      let normalized = map (\scope -> let lower = Text.toLower scope in maybe lower id (Text.stripPrefix graphRoot lower)) scopes
      in if all (`elem` normalized) ["chat.read","chatmessage.send"] then Right ()
         else Left "Teams requires Chat.Read and ChatMessage.Send in auth.scopes; run connector login after changing scopes."

login :: TeamsConfig -> PluginLogin (Either LoginError ())
login config@(TeamsConfig auth _ _) = case check config of
  Left problem -> pure (Left (LoginError problem))
  Right () -> do
    result <- Auth.login auth
    case result of
      Right () -> TeamsAuth.invalidate auth
      Left _ -> pure ()
    pure result
