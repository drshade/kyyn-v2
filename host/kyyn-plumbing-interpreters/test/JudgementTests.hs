{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module Main (main) where

import Control.Exception (AsyncException(UserInterrupt), bracket, throwIO, try)
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (unless, forM_)
import Data.Aeson (Value, object, (.=), encode, eitherDecode, toJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as Lazy
import Data.IORef (newIORef, modifyIORef', readIORef)
import Data.Text (Text)
import Effectful (Eff, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Secret (SecretError(..), secretNameText)
import Kyyn.Plumbing.Capability.Judgement
import Kyyn.Plumbing.Capability.Judgement.Jev
import Kyyn.Plumbing.Capability.SecretStore (SecretStore(..))
import Kyyn.Plumbing.Interpreter.Judgement (runJudgementWithTransport)
import Kyyn.Types.Judgement
import qualified Network.HTTP.Client as Http
import Network.HTTP.Types.Status (statusCode)
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket
import System.Timeout (timeout)

main :: IO ()
main = do
  let yes = JudgementRequest (Context "private state 雪") [YesNoRequest "Is this urgent?" "Needs action" "Can wait"]
      choice = JudgementRequest (Context "text") [ChoiceRequest "Which?" [("First","first description"),("Second","second description")]]
      scale = JudgementRequest (Context "text") [ScaleRequest "How much?" ["low","mid","high"]]
      yesResponse probability = response (object ["type" .= ("noul" :: String),"noul" .= probability])
  assert "yes probability" (decodeResponse yes (yesResponse (0.95 :: Double)) == Right [YesNoResult (YesNoAnswer 0.95)])
  forM_ [-0.1,1.1 :: Double] $ \value -> assert "out-of-range yes accepted"
    (decodeResponse yes (yesResponse value) == Left InvalidProviderResponse)
  let choiceResponse probabilities winner = response (object
        ["type" .= ("choice" :: String),"choice" .= (winner :: String),"probabilities" .= probabilities,
         "confidence" .= (0.8 :: Double)])
      distribution = object ["First" .= (0.1 :: Double),"Second" .= (0.9 :: Double)]
  assert "choice identity/distribution" (decodeResponse choice (choiceResponse distribution "Second") ==
    Right [ChoiceResult (ChoiceAnswer "Second" [("First",0.1),("Second",0.9)] 0.8)])
  assert "small rounding difference refused" (decodeResponse choice
    (choiceResponse (object ["First" .= (0.4999 :: Double),"Second" .= (0.5 :: Double)]) "Second") ==
    Right [ChoiceResult (ChoiceAnswer "Second" [("First",0.4999),("Second",0.5)] 0.8)])
  forM_ [choiceResponse distribution "Other", choiceResponse (object ["First" .= (1 :: Double)]) "First",
    choiceResponse (object ["First" .= (0.2 :: Double),"Second" .= (0.9 :: Double)]) "First"] $ \value ->
      assert "invalid choice accepted" (decodeResponse choice value == Left InvalidProviderResponse)
  let scored value = response (object ["type" .= ("score" :: String),"score" .= value,
        "legend" .= object ["0" .= ("low" :: String),"1" .= ("mid" :: String),"2" .= ("high" :: String)],
        "probabilities" .= object ["0" .= (0 :: Double),"1" .= (0.75 :: Double),"2" .= (0.25 :: Double)],
        "confidence" .= (0.7 :: Double)])
  assert "weighted score not rounded" (decodeResponse scale (scored (1.25 :: Double)) ==
    Right [ScaleResult (ScaleAnswer 1.25 [(0,0),(1,0.75),(2,0.25)] 0.7)])
  assert "wrong answer kind" (decodeResponse yes (scored (1.25 :: Double)) == Left InvalidProviderResponse)
  assert "score outside supplied levels" (decodeResponse scale (scored (3 :: Double)) == Left InvalidProviderResponse)
  forM_ [ChoiceRequest "x" [], ChoiceRequest "x" [("same","a"),("same","b")]] $ \q ->
    assert "invalid options" (case validateQuestion q of Left _ -> True; Right _ -> False)
  assert "scale limit" (case validateQuestion (ScaleRequest "x" (replicate 11 "x")) of Left _ -> True; Right _ -> False)
  let batch = JudgementRequest (Context "shared") (replicate 12 (YesNoRequest "q" "yes" "no"))
      entries = [(Key.fromString ("q" ++ show n), object ["type" .= ("noul" :: String), "noul" .= (fromIntegral n / 20 :: Double)]) | n <- [0 :: Int .. 11]]
      batchResponse values = object ["answers" .= object [key .= value | (key,value) <- values]]
  assert "numeric question order" (decodeResponse batch (batchResponse (reverse entries)) ==
    Right [YesNoResult (YesNoAnswer (fromIntegral n / 20)) | n <- [0 :: Int .. 11]])
  assert "partial batch accepted" (decodeResponse batch (batchResponse (drop 1 entries)) == Left InvalidProviderResponse)
  assert "extra answer accepted" (decodeResponse batch (batchResponse (("other",object []):entries)) == Left InvalidProviderResponse)
  assert "one invalid answer accepted" (decodeResponse batch (batchResponse (("q0",object ["type" .= ("noul" :: String),"noul" .= (2 :: Double)]):drop 1 entries)) == Left InvalidProviderResponse)
  assert "yes/no criteria not sent" (requestBody yes == object
    ["model" .= jevModel,"state" .= ("private state 雪" :: String),"questions" .= object
      ["q0" .= object ["type" .= ("noul" :: String),"instructions" .= ("Is this urgent?" :: String),
        "criteria" .= object ["true" .= ("Needs action" :: String),"false" .= ("Can wait" :: String)]]]])
  calls <- newIORef (0 :: Int)
  let transport request = do
        modifyIORef' calls (+1)
        assert "fixed endpoint" (Http.host request == "api.typesafe.ai" && Http.path request == "/v1/systemone" && Http.secure request)
        assert "bearer header" (lookup "Authorization" (Http.requestHeaders request) == Just "Bearer fixture-token")
        assert "redirects disabled" (Http.redirectCount request == 0)
        case Http.requestBody request of
          Http.RequestBodyLBS body -> assert "provider request encoding" (eitherDecode body == Right (requestBody yes))
          _ -> fail "Expected JSON body"
        pure (200, encode (yesResponse (0.95 :: Double)))
      invoke key action = runEff (secrets key (runJudgementWithTransport transport action))
  actual <- invoke (Just "fixture-token") (judge yes)
  assert "native typed dispatch" (actual == Right [YesNoResult (YesNoAnswer 0.95)])
  missing <- invoke Nothing (judge yes)
  assert "missing key is typed" (missing == Left (MissingSecret "JEV_TOKEN"))
  count <- readIORef calls
  assert "missing key called provider" (count == 1)
  forM_ [JudgementRequest (Context "") [], JudgementRequest (Context "") [YesNoRequest "q" "" "no"],
    JudgementRequest (Context "") [YesNoRequest "q" "yes" ""]] $ \invalid -> do
      result <- runEff . secrets Nothing . runJudgementWithTransport (\_ -> fail "Invalid batch reached HTTP") $ judge invalid
      assert "invalid batch looked up key or succeeded" (case result of Left (InvalidQuestion _) -> True; _ -> False)
  forM_ [(401,AuthenticationRejected),(403,AuthenticationRejected),(429,RateLimited),
    (500,ProviderUnavailable),(529,ProviderUnavailable),(422,RequestRejected),(302,RequestRejected)] $ \(status,failure) -> do
      result <- runEff . secrets (Just "fixture-token") . runJudgementWithTransport (\_ -> pure (status,"private provider response")) $ judge yes
      assert "HTTP status mapping" (result == Left failure)
  malformed <- runEff . secrets (Just "fixture-token") . runJudgementWithTransport (\_ -> pure (200,"not json private provider response")) $ judge yes
  assert "malformed provider body" (malformed == Left InvalidProviderResponse)
  unavailable <- runEff . secrets (Just "fixture-token") . runJudgementWithTransport
    (\request -> throwIO (Http.HttpExceptionRequest request Http.ConnectionTimeout)) $ judge yes
  assert "transport failure not typed" (unavailable == Left ProviderUnavailable)
  cancelled <- try @AsyncException (runEff . secrets (Just "fixture-token") . runJudgementWithTransport
    (\_ -> throwIO UserInterrupt) $ judge yes)
  assert "cancellation swallowed" (case cancelled of Left UserInterrupt -> True; _ -> False)
  localExchange yes (yesResponse (0.95 :: Double))
  putStrLn "Judgement provider codec and native handler tests passed (no live provider)."

localExchange :: JudgementRequest -> Value -> IO ()
localExchange question reply = do
  outcome <- timeout 5000000 $ bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \listener -> do
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127,0,0,1)))
    Socket.listen listener 1
    address <- Socket.getSocketName listener
    port <- case address of Socket.SockAddrInet value _ -> pure (fromIntegral value); _ -> fail "Not IPv4"
    finished <- newEmptyMVar
    let server = bracket (fst <$> Socket.accept listener) Socket.close $ \connection -> do
          let readRequest accumulated = do
                chunk <- Socket.recv connection 4096
                assert "HTTP request ended early" (not (Bytes.null chunk))
                let received = accumulated <> chunk
                    (_,body) = Bytes.breakSubstring "\r\n\r\n" received
                if Bytes.length body < 4 + fromIntegral (Lazy.length (encode (requestBody question)))
                  then readRequest received else pure received
          received <- readRequest Bytes.empty
          assert "HTTP auth missing" ("Authorization: Bearer fixture-token" `Bytes.isInfixOf` received)
          let bytes = Lazy.toStrict (encode reply)
          Socket.sendAll connection ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " <>
            Char8.pack (show (Bytes.length bytes)) <> "\r\nConnection: close\r\n\r\n" <> bytes)
    bracket (forkFinally server (putMVar finished)) killThread $ \_ -> do
      manager <- Http.newManager Http.defaultManagerSettings { Http.managerRetryableException = const False }
      let transport request = do
            responseValue <- Http.httpLbs request { Http.host = "127.0.0.1", Http.port = port,
              Http.secure = False, Http.proxy = Nothing } manager
            pure (statusCode (Http.responseStatus responseValue), Http.responseBody responseValue)
      result <- runEff . secrets (Just "fixture-token") . runJudgementWithTransport transport $ judge question
      assert "local HTTP result" (result == Right [YesNoResult (YesNoAnswer 0.95)])
      takeMVar finished >>= either throwIO pure
  assert "local HTTP fixture timed out" (case outcome of Just () -> True; Nothing -> False)

response :: Value -> Value
response answerValue = object ["model" .= ("actual-model" :: String),"answers" .= object ["q0" .= answerValue],"usage" .= toJSON (0 :: Integer)]

secrets :: Maybe Text -> Eff (SecretStore : es) a -> Eff es a
secrets value = interpret $ \_ operation -> case operation of
  ReadSecret name | secretNameText name == "JEV_TOKEN" -> pure (maybe (Left (SecretNotFound name)) Right value)
  _ -> error "Unexpected secret operation"

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)
