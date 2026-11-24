module MicrosoftGraph.Teams.Auth (getPage, invalidate) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Aeson as Aeson
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Kyyn.Plugin.Host
import Kyyn.Plugin.Event (LiveEvent)
import MicrosoftGraph.Types (GraphAuth(..))
import qualified MicrosoftGraph.Auth as Auth
import MicrosoftGraph.Teams.Api (response)

-- Access tokens stay in the secret store, never in an inspectable event cursor.
getPage :: GraphAuth -> Text -> LiveEvent (Either Text Aeson.Value)
getPage auth url = runExceptT $ do
  token <- ExceptT (cachedToken auth)
  first <- lift (get token)
  case first of
    Right (HttpResponse 401 _ _) -> do
      fresh <- ExceptT (refresh auth)
      second <- lift (get fresh)
      either throwE pure (response "GET" second)
    _ -> either throwE pure (response "GET" first)
  where
    get token = sendHttp (HttpRequest "GET" url [("Authorization","Bearer " <> token)] "")

cachedToken :: GraphAuth -> LiveEvent (Either Text Text)
cachedToken auth@(DeviceCode _ _ key _) = do
  found <- getSecret (key <> "-access")
  case found of
    Right token | not (Text.null token) -> pure (Right token)
    _ -> refresh auth
cachedToken ClientSecret {} = pure (Left "Teams conversation requires delegated authentication.")

refresh :: GraphAuth -> LiveEvent (Either Text Text)
refresh auth@(DeviceCode _ _ key _) = do
  token <- Auth.accessToken auth
  case token of
    Right value -> putSecret (key <> "-access") value
    Left _ -> pure ()
  pure token
refresh ClientSecret {} = pure (Left "Teams conversation requires delegated authentication.")

invalidate :: GraphAuth -> PluginLogin ()
invalidate (DeviceCode _ _ key _) = putSecret (key <> "-access") ""
invalidate ClientSecret {} = pure ()
