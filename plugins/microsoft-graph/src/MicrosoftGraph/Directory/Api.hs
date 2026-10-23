{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Directory.Api (listing, endpoint) where
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (sortOn, groupBy)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin.Host
import MicrosoftGraph.Config (graphApiBase)
import MicrosoftGraph.Directory.Types (DirectoryUser(..))
import qualified MicrosoftGraph.Directory.Types as Directory
import qualified MicrosoftGraph.Http as Http
import qualified MicrosoftGraph.Json as Json
import Text.JSON.Types (JSValue(..))

endpoint :: Text
endpoint = graphApiBase <> "users?$select=id,displayName,givenName,surname,mail,userPrincipalName,accountEnabled,userType&$top=999"

listing :: Text -> Acquisition payload (Either Text [DirectoryUser])
listing token = runExceptT $ do
  rows <- pages [] endpoint
  let sorted = sortOn Directory.id rows
  if any ((>1) . length) (groupBy (\a b -> Directory.id a == Directory.id b) sorted)
    then throwE "Directory returned duplicate user IDs; retry the complete snapshot"
    else pure sorted
  where
    pages seen url
      | url `elem` seen = throwE "Directory pagination repeated a page"
      | not (graphApiBase `Text.isPrefixOf` url) = throwE "Unexpected Graph pagination URL"
      | otherwise = do
          response <- ExceptT (Http.send (HttpRequest "GET" url [("Authorization","Bearer " <> token)] ""))
          body <- case response of
            HttpResponse 403 _ _ -> throwE "Cannot read directory; check User.Read.All, admin consent and the signed-in user's directory access"
            _ -> either throwE pure (Http.requireSuccess response)
          value <- either throwE pure (Json.parse body)
          rows <- either throwE pure (Json.member "value" value >>= Json.array >>= mapM user)
          next <- either throwE pure (Json.optionalText "@odata.nextLink" value)
          rest <- maybe (pure []) (pages (url:seen)) next
          pure (rows ++ rest)

user :: JSValue -> Either Text DirectoryUser
user value = do
  key <- Json.member "id" value >>= Json.text
  if Text.null key then Left "Directory user has an empty ID" else pure ()
  DirectoryUser key <$> nullable "displayName" Json.text <*> nullable "givenName" Json.text
    <*> nullable "surname" Json.text <*> nullable "mail" Json.text <*> nullable "userPrincipalName" Json.text
    <*> nullable "accountEnabled" Json.boolean <*> nullable "userType" Json.text
  where
    nullable field decode = do
      item <- Json.member field value
      case item of JSNull -> Right Nothing; _ -> Just <$> decode item
