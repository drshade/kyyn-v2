{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Login (login) where
import Kyyn.Plugin.Host
import MicrosoftGraph.Types
import qualified MicrosoftGraph.Auth as Auth
login :: CalendarConfig -> PluginLogin (Either LoginError ())
login (CalendarConfig auth _ _ _ _ _) = Auth.login auth
