module MicrosoftGraph.Login (login) where
import Kyyn.Plugin.Host
import MicrosoftGraph.Types
import MicrosoftGraph.Config (scope)
import qualified MicrosoftGraph.Auth as Auth
login :: CalendarConfig -> PluginLogin (Either LoginError ())
login config@(CalendarConfig auth _ _ _) = Auth.login auth (scope config)
