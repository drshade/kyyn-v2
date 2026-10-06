{-# LANGUAGE OverloadedStrings #-}
module Fixture.Login where
import Fixture.Types
import Kyyn.Plugin.Host
login :: Config -> PluginLogin (Either LoginError ())
login (Config endpoint key _) = do
  displayInstructions "Fixture login instructions"
  waitSeconds 0
  response <- sendHttp (HttpRequest "POST" (endpoint <> "/login") [] "")
  case response of
    Right (HttpResponse 200 _ token) -> putSecret key token >> pure (Right ())
    _ -> pure (Left (LoginError "Fixture login failed"))
