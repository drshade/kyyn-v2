module MicrosoftGraph.Teams.Conversation (dispatch, poll) where

import qualified Data.Text as Text
import qualified Data.Aeson as Aeson
import Data.Maybe (catMaybes, maybeToList)
import Data.List (sortOn)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Kyyn.Plugin (FetchError(..))
import Kyyn.Plugin.Event
import MicrosoftGraph.Teams.Types
import MicrosoftGraph.Teams.Config (check)
import MicrosoftGraph.Teams.Text (plainText, messageSize)
import MicrosoftGraph.Teams.Api
import MicrosoftGraph.Timestamp (timestamp)
import qualified MicrosoftGraph.Teams.Event as Question
import qualified MicrosoftGraph.Json as Json
import qualified MicrosoftGraph.Teams.Auth as Auth

dispatch :: TeamsConfig -> EventDispatch Question -> LiveEvent (Either FetchError ConversationCursor)
dispatch config input@(EventDispatch _ (Question content))
  | messageSize content > 24000 = pure (Left (FetchError "Teams conversation message exceeds the 24000-byte UTF-8 limit; shorten it before sending."))
  | otherwise = fmap (fmap (\sent -> ConversationCursor sent Nothing)) (Question.dispatch config input)

poll :: TeamsConfig -> EventPoll Question ConversationCursor -> LiveEvent (Either FetchError (EventBatch ChatReply ConversationCursor))
poll config@(TeamsConfig auth chat _) (EventPoll _ _ prior) = fmap (either (Left . FetchError) Right) $ runExceptT $ do
  either throwE pure (check config)
  ConversationCursor sent@(Cursor key created continuation) saved <- maybe (throwE "Teams conversation requires a completed dispatch.") pure prior
  _ <- either throwE pure (timestamp created)
  let initial = messagesUrl config <> "?$top=50&$orderby=lastModifiedDateTime%20desc&$filter=" <>
        Json.escape ("lastModifiedDateTime gt " <> created)
      oldest candidates = case sortOn (\(Reply identity _ time _ _) -> (timestamp time,identity)) candidates of
        [] -> Nothing
        first:_ -> Just first
      pages 0 _ _ best url = pure (best,Just url)
      pages budget restart seen best url = do
        fetched <- case checkedPage config url of
          Left problem -> pure (Left problem)
          Right checked -> if checked `elem` seen then pure (Left "Teams conversation pagination repeated a page.") else
            lift (Auth.getPage auth checked)
        case fetched of
          Left _ | restart -> pages (budget - 1) False [] Nothing initial
          Left problem -> throwE problem
          Right value -> do
            rows <- either throwE pure (Json.member "value" value >>= Json.array)
            candidates <- either throwE pure (catMaybes <$> mapM (ordinaryReply config sent) rows)
            let nextBest = oldest (maybeToList best <> candidates)
            next <- either throwE pure (Json.optionalText "@odata.nextLink" value)
            case next of
              Nothing -> pure (nextBest,Nothing)
              Just link -> do
                _ <- either throwE pure (checkedPage config link)
                if link `elem` (url:seen) then throwE "Teams conversation pagination repeated a page." else pure ()
                pages (budget - 1) False (url:seen) nextBest link
  (best,next) <- pages (4 :: Int) (continuation /= Nothing) [] saved (maybe initial id continuation)
  let arrival message@(Reply identity _ _ kind body) =
        EventArrival (EventIdentity (encode (Aeson.toJSON [chat,identity])))
          (ChatReply message (if kind == "html" then plainText body else Text.unwords (Text.words body)))
  pure $ case next of
    Just _ -> EventBatch [] (ConversationCursor (Cursor key created next) best)
    Nothing -> EventBatch (map arrival (maybeToList best)) (ConversationCursor (Cursor key created Nothing) Nothing)
