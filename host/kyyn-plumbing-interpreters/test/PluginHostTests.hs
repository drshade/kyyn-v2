-- Recording/loopback HTTP handling: UTF-8, sanitized failures, method/header
-- injection refusal, redirects and cancellable waits; no provider credentials.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch, withAsync, wait)
import Control.Exception (AsyncException(UserInterrupt), bracket, throwIO, try, toException)
import Control.Monad (unless, forM_)
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString.Char8 as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runEff)
import Kyyn.Plumbing.Capability.HttpTransport
import Kyyn.Plumbing.Capability.PluginInteraction (waitSeconds)
import Kyyn.Plumbing.Interpreter.HttpTransport
import Kyyn.Plumbing.Interpreter.PluginInteraction (runWaitingIO)
import qualified Network.HTTP.Client as Http
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket
import System.Timeout (timeout)

main :: IO ()
main = do
  let request = HttpRequest "POST" "https://example.test/token?private-query" [("Authorization","secret"),("X-Text","雪")] "body 雪"
      utf8 = Text.encodeUtf8 . Text.pack
      transport native = do
        assert "method" (Http.method native == "POST")
        assert "headers" (lookup "Authorization" (Http.requestHeaders native) == Just "secret" &&
          lookup "X-Text" (Http.requestHeaders native) == Just (utf8 "雪"))
        assert "body" (case Http.requestBody native of Http.RequestBodyBS bytes -> bytes == utf8 "body 雪"; _ -> False)
        assert "no implicit redirects" (Http.redirectCount native == 0)
        pure (429,[("Retry-After","2")],Lazy.fromStrict (utf8 "response 雪"))
  result <- runEff . runHttpTransportWith transport $ sendHttp request
  assert "status/header/body preserved" (result == Right (HttpResponse 429 [("Retry-After","2")] "response 雪"))
  forM_ [HttpRequest "GET\r\nX: injected" "https://example.test" [] "",
    HttpRequest "GET" "https://example.test" [("Bad:Name","value")] "",
    HttpRequest "GET" "https://example.test" [("Good","value\r\nInjected: true")] "",
    HttpRequest "雪" "https://example.test" [] "",
    HttpRequest "GET" "not-a-url" [] ""] $ \invalid -> do
      refused <- runEff . runHttpTransportWith (\_ -> fail "Invalid input reached transport") $ sendHttp invalid
      assert "invalid request refused" (refused == Left InvalidHttpRequest)
  forM_ [200,302,401,403,429,503] $ \status -> do
    response <- runEff . runHttpTransportWith (\_ -> pure (status,[],"body")) $ sendHttp request
    assert "status treated as data" (response == Right (HttpResponse status [] "body"))
  invalidText <- runEff . runHttpTransportWith (\_ -> pure (200,[],Lazy.pack [255])) $ sendHttp request
  assert "invalid UTF-8" (invalidText == Left InvalidHttpResponse)
  forM_ [(Http.ConnectionTimeout,HttpTimedOut),(Http.ResponseTimeout,HttpTimedOut),
    (Http.ConnectionFailure (toException (userError "private socket details")),HttpConnectionFailed),
    (Http.ConnectionClosed,HttpConnectionFailed),
    (Http.InternalException (toException (userError "private TLS details")),HttpUnavailable)] $ \(cause,expected) -> do
    failed <- runEff . runHttpTransportWith (\native -> throwIO (Http.HttpExceptionRequest native cause)) $ sendHttp request
    assert "transport category and redaction" (failed == Left expected)
  interrupted <- try @AsyncException (runEff . runHttpTransportWith (\_ -> throwIO UserInterrupt) $ sendHttp request)
  assert "HTTP cancellation propagated" (case interrupted of Left UserInterrupt -> True; _ -> False)
  zero <- timeout 100000 (runEff . runWaitingIO $ waitSeconds 0)
  assert "zero delay" (zero == Just ())
  delayed <- async (runEff . runWaitingIO $ waitSeconds maxBound)
  threadDelay 10000
  stopped <- timeout 1000000 (cancel delayed >> waitCatch delayed)
  assert "long wait cancellable without integer overflow" (case stopped of Just (Left _) -> True; _ -> False)
  localExchange
  putStrLn "Plugin HTTP transport and cancellable wait tests passed."

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

localExchange :: IO ()
localExchange = do
  completed <- timeout 5000000 $ bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \listener -> do
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127,0,0,1)))
    Socket.listen listener 1
    address <- Socket.getSocketName listener
    port <- case address of Socket.SockAddrInet value _ -> pure (show value); _ -> fail "Expected IPv4"
    let server = bracket (fst <$> Socket.accept listener) Socket.close $ \connection -> do
          let readHeaders accumulated = do
                chunk <- Socket.recv connection 4096
                assert "request ended before headers" (not (Bytes.null chunk))
                let received = accumulated <> chunk
                if "\r\n\r\n" `Bytes.isInfixOf` received then pure received else readHeaders received
          received <- readHeaders Bytes.empty
          assert "empty GET sent a Content-Length header" (not ("content-length:" `Bytes.isInfixOf` Bytes.map lowerAscii received))
          Socket.sendAll connection "HTTP/1.1 302 Found\r\nLocation: /must-not-follow\r\nRetry-After: 2\r\nContent-Length: 4\r\nConnection: close\r\n\r\nbody"
    withAsync server $ \worker -> do
      response <- runEff . runHttpTransportIO $ sendHttp (HttpRequest "GET" ("http://127.0.0.1:" ++ port ++ "/") [] "")
      assert "native transport followed redirect or lost headers" (case response of
        Right (HttpResponse 302 fields "body") -> lookup "Retry-After" fields == Just "2"
        _ -> False)
      wait worker
  assert "native HTTP loopback timed out" (completed == Just ())

lowerAscii :: Char -> Char
lowerAscii c | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
             | otherwise = c
