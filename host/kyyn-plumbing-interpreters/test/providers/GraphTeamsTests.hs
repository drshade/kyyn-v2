-- Actual Nix-built plugin event entry points with synthetic HTTP and secrets.
-- Verifies discovery, dispatch cursor and resumed quote polling wire contracts.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import ProviderBroker
import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=), (.:), encode)
import qualified Data.Aeson.Key
import Data.Aeson.Types (parseEither, withObject, FromJSON)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import System.Exit (ExitCode(..))

main :: IO ()
main = do
  dispatch <- nativeEvent "microsoft-graph" "Teams" "question" True
  poll <- nativeEvent "microsoft-graph" "Teams" "question" False
  let request = object ["text" .= text "Please reply to this question"]
      envelope fields = object ["config" .= config,"input" .= object fields]
  (sent,_,exit) <- brokerWith Normal respond dispatch (envelope ["waitIdentity" .= text "w","request" .= request])
  assert "dispatch exit" (exit == ExitSuccess)
  cursor <- maybe (fail "Missing dispatch result") (get "value") sent :: IO Value
  assert "question id" . (== ("question" :: Text.Text)) =<< get "questionId" cursor
  (received,_,pollExit) <- brokerWith Normal respond poll (envelope ["waitIdentity" .= text "w","request" .= request,"cursor" .= tagged "Some" cursor])
  assert "poll exit" (pollExit == ExitSuccess)
  batch <- maybe (fail "Missing poll result") (get "value") received :: IO Value
  arrivals <- get "arrivals" batch :: IO [Value]
  assert "one quoted answer" (length arrivals == 1)
  entry <- case arrivals of [entry] -> pure entry; _ -> fail "Expected one answer"
  reply <- get "value" entry :: IO Value
  assert "answer" . (== ("Answer" :: Text.Text)) =<< get "content" reply
  putStrLn "Teams real guest: discovery, delegated dispatch and quoted reply passed."

config :: Value
config = object ["auth" .= tagged "DeviceCode" (object ["tenant" .= text "tenant","clientId" .= text "client","tokenKey" .= text "teams-test","scopes" .= map text ["Chat.Read","ChatMessage.Send"]]),"chatId" .= text "chat","respondentId" .= text "person"]
respond :: Bytes.ByteString -> String -> String -> Value -> IO (Value,Bytes.ByteString)
respond _ "secrets" "get" _ = pure (tagged "Right" (text "synthetic"),Bytes.empty)
respond _ "http" "send" args = do
  url <- get "url" args :: IO Text.Text
  method <- get "method" args :: IO Text.Text
  if "https://login.microsoftonline.com/" `Text.isPrefixOf` url
    then pure (http 200 (object ["access_token" .= text "token"]))
    else do
      assert "Graph destination" ("https://graph.microsoft.com/v1.0/chats/chat/messages" `Text.isPrefixOf` url)
      pure $ if method == "POST" then http 201 (object ["id" .= text "question","chatId" .= text "chat","createdDateTime" .= text "2026-11-24T10:00:00Z"])
        else http 200 (object ["value" .= [object
          ["id" .= text "reply","chatId" .= text "chat","messageType" .= text "message","createdDateTime" .= text "2026-11-24T10:01:00Z"
          ,"from" .= object ["user" .= object ["id" .= text "person"]]
          ,"attachments" .= [object ["id" .= text "question","contentType" .= text "messageReference"]]
          ,"body" .= object ["contentType" .= text "text","content" .= text "Answer"]]]])
respond _ _ _ _ = fail "Unexpected Teams capability"
http :: Int -> Value -> (Value,Bytes.ByteString)
http status body = (tagged "Right" (object ["status" .= show status,"headers" .= ([] :: [Value])]),Lazy.toStrict (encode body))
text :: Text.Text -> Value
text = String
tagged :: Text.Text -> Value -> Value
tagged tag value = object ["tag" .= tag,"value" .= value]
get :: FromJSON a => Text.Text -> Value -> IO a
get key value = either fail pure (parseEither (withObject "object" (.: fromStringKey key)) value)
  where fromStringKey = Data.Aeson.Key.fromText
assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)
