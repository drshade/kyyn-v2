module MicrosoftGraph.Teams.Event (dispatch, poll) where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.List (sortOn)
import Data.Maybe (catMaybes)
import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Kyyn.Plugin (FetchError(..))
import Kyyn.Plugin.Host (HttpRequest(..))
import Kyyn.Plugin.Event
import MicrosoftGraph.Teams.Types
import MicrosoftGraph.Teams.Config (check)
import MicrosoftGraph.Teams.Api
import MicrosoftGraph.Timestamp (timestamp)
import qualified MicrosoftGraph.Json as Json
import qualified MicrosoftGraph.Auth as Auth

dispatch :: TeamsConfig -> EventDispatch Question -> LiveEvent (Either FetchError Cursor)
dispatch config@(TeamsConfig auth chat _) (EventDispatch _ (Question question)) = result $ do
  either throwE pure (check config)
  if Text.null (Text.strip question) then throwE "Teams question must not be empty." else pure ()
  token <- ExceptT (Auth.accessToken auth)
  value <- ExceptT (send (HttpRequest "POST" (messagesUrl config)
    [("Authorization","Bearer " <> token),("Content-Type","application/json")]
    (encode (Aeson.object ["body" .= Aeson.object ["contentType" .= ("text" :: Text),"content" .= question]]))))
  actualChat <- either throwE pure (nonempty "chatId" value)
  if actualChat == chat then pure () else throwE "Teams dispatch returned a different chat."
  key <- either throwE pure (nonempty "id" value)
  created <- either throwE pure (nonempty "createdDateTime" value)
  _ <- either throwE pure (timestamp created)
  pure (Cursor key created Nothing)

poll :: TeamsConfig -> EventPoll Question Cursor -> LiveEvent (Either FetchError (EventBatch Reply Cursor))
poll config@(TeamsConfig auth chat _) (EventPoll _ _ prior) = result $ do
  either throwE pure (check config)
  cursor@(Cursor key created continuation) <- maybe (throwE "Teams polling requires a completed question dispatch.") pure prior
  _ <- either throwE pure (timestamp created)
  token <- ExceptT (Auth.accessToken auth)
  -- Read from the question floor again after a complete scan. A creation-time
  -- cursor cannot prove that eventually visible replies have all arrived.
  let initial = messagesUrl config <> "?$top=50&$orderby=lastModifiedDateTime%20desc&$filter=" <>
        Json.escape ("lastModifiedDateTime gt " <> created)
      pages 0 _ _ url = pure ([],Just url)
      pages remaining restart seen url = do
        fetched <- case checkedPage config url of
          Left problem -> pure (Left problem)
          Right checked -> if checked `elem` seen then pure (Left "Teams pagination repeated a page.") else
            lift (send (HttpRequest "GET" checked [("Authorization","Bearer " <> token)] ""))
        case fetched of
          Left _ | restart -> pages (remaining - 1) False [] initial
          Left problem -> throwE problem
          Right value -> consume remaining seen url value
      consume remaining seen url value = do
        rows <- either throwE pure (Json.member "value" value >>= Json.array)
        replies <- either throwE pure (catMaybes <$> mapM (reply config cursor) rows)
        next <- either throwE pure (Json.optionalText "@odata.nextLink" value)
        case next of
          Nothing -> pure (replies,Nothing)
          Just link -> do
            _ <- either throwE pure (checkedPage config link)
            if link `elem` (url:seen) then throwE "Teams pagination repeated a page." else pure ()
            (more,final) <- pages (remaining - 1) False (url:seen) link
            pure (replies <> more,final)
  (replies,next) <- pages (4 :: Int) (continuation /= Nothing) [] (maybe initial id continuation)
  let ordered = sortOn (\(Reply message _ time _ _) -> (timestamp time,message)) replies
      arrival value@(Reply message _ _ _ _) = EventArrival (EventIdentity (encode (Aeson.toJSON [chat,message]))) value
  pure (EventBatch (map arrival ordered) (Cursor key created next))

result :: ExceptT Text LiveEvent a -> LiveEvent (Either FetchError a)
result = fmap (either (Left . FetchError) Right) . runExceptT
