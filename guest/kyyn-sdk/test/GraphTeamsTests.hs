-- Teams questions against a synthetic HTTP interpreter. Exercises filtering,
-- pagination, initialCursor replay and failures without network or real credentials.
{-# LANGUAGE GADTs, TypeOperators, OverloadedStrings #-}
module Main where

import Control.Monad (unless, forM_)
import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as Keys
import Data.Aeson ((.=))
import Kyyn.Types.Program hiding (request)
import Kyyn.Types.PluginHost
import Kyyn.Plugin (FetchError(..))
import Kyyn.Plugin.Event
import MicrosoftGraph.Types (GraphAuth(..))
import MicrosoftGraph.Teams.Types
import qualified MicrosoftGraph.Teams.Event as Event
import qualified MicrosoftGraph.Teams.Config as Config
import qualified MicrosoftGraph.Teams.Api as Api

main :: IO ()
main = do
  let dispatch = Event.dispatch config (EventDispatch (WaitId "w") (Question "Question"))
  (sent,trace,rotated) <- run [ok 201 sentMessage] dispatch
  assert "dispatch initialCursor" (sent == Right initialCursor)
  assert "refresh rotation" (rotated == ["rotated"])
  assert "single POST" (length trace == 1 && all (\(HttpRequest method _ _ _) -> method == "POST") trace)
  forM_ [Left HttpTimedOut,Left HttpConnectionFailed,ok 500 A.Null,ok 429 A.Null,ok 200 sentMessage] $ \response -> do
    (failed,requests,_) <- run [response] dispatch
    assert "failed dispatch never repeated" (isLeft failed && length requests == 1)
  forM_ [config { auth = ClientSecret "tenant" "app" "secret" },config { respondentId = "" },config { auth = DeviceCode "tenant" "app" "secret" ["Chat.Read"] }] $ \bad -> do
    assert "invalid config" (isLeft (Config.check bad))
    (invalid,requests,_) <- run [] (Event.dispatch bad (EventDispatch (WaitId "w") (Question "Q")))
    assert "invalid config did not send" (isLeft invalid && null requests)
  let good = message "reply" "person" ["question"] "2026-11-24T10:01:00Z" "Answer"
      unrelated = [message "question" "person" [] created "Question",
        message "old" "person" ["question"] created "Old",
        message "stranger" "other" ["question"] later "No",
        message "other-question" "person" ["different"] later "No",
        message "ambiguous" "person" ["question","different"] later "No",
        message "unquoted" "person" [] later "No"]
      expected = Reply "reply" "person" "2026-11-24T10:01:00Z" "html" "Answer"
      polling = Event.poll config (EventPoll (WaitId "w") (Question "Q") (Just initialCursor))
  (batch,_,_) <- run [ok 200 (page (unrelated <> [good]) Nothing)] polling
  assert "only quoted respondent answer including self chat" (batch == Right (EventBatch [arrival expected] initialCursor))
  (repeated,_,_) <- run [ok 200 (page [good] Nothing)] polling
  assert "repeated poll stable" (repeated == batch)
  let reaction = add "lastModifiedDateTime" (A.String "2026-11-24T12:00:00Z") (add "etag" (A.String "changed") good)
  (reacted,_,_) <- run [ok 200 (page [reaction] Nothing)] polling
  assert "reaction churn excluded" (reacted == batch)
  let quoted = message "reply" "person" ["question"] "2026-11-24T10:01:00Z" "<attachment id=\"question\"></attachment>Answer"
  (stripped,_,_) <- run [ok 200 (page [quoted] Nothing)] polling
  assert "quote placeholder removed" (stripped == batch)
  let malformed = [A.Null, add "attachments" A.Null good,
        add "messageType" (A.String "systemEventMessage") good,
        add "deletedDateTime" (A.String later) good,
        add "attachments" (A.toJSON [A.object ["id" .= ("question" :: Text),"contentType" .= ("messageReference" :: Text),"content" .= ("{\"messageId\":\"wrong\"}" :: Text)]]) good,
        add "attachments" (A.toJSON [A.object ["id" .= ("question" :: Text),"contentType" .= ("forwardedMessageReference" :: Text)]]) good]
  (usable,_,_) <- run [ok 200 (page (malformed <> [good]) Nothing)] polling
  assert "unusable candidates do not poison wait" (usable == batch)
  let edited = message "reply" "person" ["question"] "2026-11-24T10:01:00Z" "Edited"
  (changed,_,_) <- run [ok 200 (page [edited] Nothing)] polling
  assert "edit preserves event identity but changes reply" (changed == Right (EventBatch [arrival (expected { content = "Edited" })] initialCursor))
  (other,_,_) <- run [ok 200 (page [good] Nothing)] (Event.poll config (EventPoll (WaitId "other") (Question "Q") (Just (Cursor "different" created Nothing))))
  assert "concurrent question isolation" (other == Right (EventBatch [] (Cursor "different" created Nothing)))
  let link n = Api.messagesUrl config <> "?page=" <> Text.pack (show (n :: Int))
  (partial,requests,_) <- run [ok 200 (page [] (Just (link n))) | n <- [1..4]] polling
  assert "page budget" (length requests == 4 && partial == Right (EventBatch [] (Cursor "question" created (Just (link 4)))))
  (continued,continuedTrace,_) <- run [ok 200 (page [good] Nothing)] (Event.poll config (EventPoll (WaitId "w") (Question "Q") (Just (Cursor "question" created (Just (link 4))))))
  assert "continuation publishes and resets scan" (continued == batch && case continuedTrace of [HttpRequest _ url _ _] -> url == link 4; _ -> False)
  let resumed = Event.poll config (EventPoll (WaitId "w") (Question "Q") (Just (Cursor "question" created (Just (link 4)))))
  forM_ [400,410,500] $ \status -> do
    (restarted,tries,_) <- run [ok status A.Null,ok 200 (page [good] Nothing)] resumed
    assert "expired continuation restarts from question floor" (restarted == batch && length tries == 2)
  let refused = Event.poll config (EventPoll (WaitId "w") (Question "Q") (Just (Cursor "question" created (Just "https://evil.invalid/page"))))
  (restarted,tries,_) <- run [ok 200 (page [good] Nothing)] refused
  assert "refused saved continuation restarts without sending credential" (restarted == batch && length tries == 1)
  let colonConfig = config { chatId = "19:chat@thread.v2" }
  forM_ ["https://graph.microsoft.com/v1.0/chats/19:chat@thread.v2/messages?$skiptoken=x",
         "https://GRAPH.MICROSOFT.COM/v1.0/chats/19%3achat%40thread.v2/messages?$skiptoken=x"] $ \url ->
    assert "equivalent Graph encodings" (Api.checkedPage colonConfig url == Right url)
  forM_ ["http://graph.microsoft.com/v1.0/chats/chat/messages", "https://user:pass@graph.microsoft.com/v1.0/chats/chat/messages", "https://graph.microsoft.com:444/v1.0/chats/chat/messages"] $ \url ->
    assert "unsafe Graph continuation" (isLeft (Api.checkedPage config url))
  forM_ ["https://evil.invalid/messages?page=2", Api.messagesUrl config <> "/wrong?page=2"] $ \foreignLink -> do
    (bad,rs,_) <- run [ok 200 (page [] (Just foreignLink))] polling
    assert "foreign continuation refused" (isLeft bad && length rs == 1)
  forM_ [ok 401 A.Null,ok 403 A.Null,ok 500 A.Null,ok 200 A.Null,Right (HttpResponse 200 [] "invalid")] $ \response -> do
    (bad,_,_) <- run [response] polling
    assert "failed poll has no batch or initialCursor" (isLeft bad)
  (lateFailure,_,_) <- run [ok 200 (page [good] (Just (link 1))),ok 500 A.Null] polling
  assert "late page error publishes no partial result" (isLeft lateFailure)
  (throttled,_,_) <- run [Right (HttpResponse 429 [("Retry-After","120")] "")] polling
  assert "long retry-after reported promptly" (case throttled of Left (FetchError problem) -> "Retry-After: 120" `Text.isInfixOf` problem; _ -> False)
  (missing,rs,_) <- run [] (Event.poll config (EventPoll (WaitId "w") (Question "Q") Nothing))
  assert "no poll before dispatch" (isLeft missing && null rs)
  putStrLn "Teams: dispatch, auth, quotes, self-chat, duplicate/edit identity, paging and failures passed."

config :: TeamsConfig
config = TeamsConfig (DeviceCode "tenant" "app" "secret" ["Chat.Read","ChatMessage.Send"]) "chat" "person"
created, later :: Text
created = "2026-11-24T10:00:00Z"
later = "2026-11-24T10:02:00Z"
initialCursor :: Cursor
initialCursor = Cursor "question" created Nothing
sentMessage :: A.Value
sentMessage = A.object ["id" .= ("question" :: Text),"chatId" .= ("chat" :: Text),"createdDateTime" .= created]
message :: Text -> Text -> [Text] -> Text -> Text -> A.Value
message key sender refs time body = A.object
  ["id" .= key,"chatId" .= ("chat" :: Text),"messageType" .= ("message" :: Text),"createdDateTime" .= time
  ,"from" .= A.object ["user" .= A.object ["id" .= sender]]
  ,"attachments" .= [A.object ["contentType" .= ("messageReference" :: Text),"id" .= ref,"content" .= Api.encode (A.object ["messageId" .= ref])] | ref <- refs]
  ,"body" .= A.object ["contentType" .= ("html" :: Text),"content" .= body]]
page :: [A.Value] -> Maybe Text -> A.Value
page rows next = A.object ["value" .= rows,"@odata.nextLink" .= next]
arrival :: Reply -> EventArrival Reply
arrival reply@(Reply key _ _ _ _) = EventArrival (EventIdentity (Api.encode (A.toJSON (["chat",key] :: [Text])))) reply
ok :: Int -> A.Value -> Either HttpError HttpResponse
ok status body = Right (HttpResponse status [] (Api.encode body))
add :: A.Key -> A.Value -> A.Value -> A.Value
add key value (A.Object fields) = A.Object (Keys.insert key value fields)
add _ _ value = value

run :: [Either HttpError HttpResponse] -> LiveEvent a -> IO (a,[HttpRequest],[Text])
run responses program = do
  remaining <- newIORef responses
  trace <- newIORef []
  rotated <- newIORef []
  let handle :: (Http :+: (Secrets :+: Waiting)) a -> IO a
      handle (InLeft (SendHttp request@(HttpRequest _ url _ _)))
        | "https://login.microsoftonline.com/" `Text.isPrefixOf` url = pure (ok 200 (A.object ["access_token" .= ("token" :: Text),"refresh_token" .= ("rotated" :: Text)]))
        | otherwise = do
          modifyIORef' trace (<> [request])
          queued <- readIORef remaining
          case queued of
            [] -> fail "Unexpected HTTP request or retry"
            response:rest -> writeIORef remaining rest >> pure response
      handle (InRight (InLeft (GetSecret _))) = pure (Right "synthetic-refresh")
      handle (InRight (InLeft (PutSecret _ token))) = modifyIORef' rotated (<> [token])
      handle (InRight (InRight (WaitSeconds _))) = fail "Teams adapter unexpectedly slept"
  result <- interpretProgram handle program
  assert "unused synthetic responses" . null =<< readIORef remaining
  (,,) result <$> readIORef trace <*> readIORef rotated
assert :: String -> Bool -> IO ()
assert label value = unless value (fail label)
