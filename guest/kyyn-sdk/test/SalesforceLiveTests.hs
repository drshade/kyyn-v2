-- Provider-free response tests for bounded live SOQL; replay is an installed journey.
{-# LANGUAGE GADTs, TypeOperators #-}
module Main where

import Control.Monad (unless, forM_)
import Data.IORef
import Kyyn.Types.Program
import Kyyn.Types.PluginHost
import Kyyn.Types.Plugin (FetchError(..))
import qualified Salesforce.Live as Live
import qualified Salesforce.Types as Auth
import qualified Data.Text as Text
import Salesforce.Live (decodeResponse)
import Salesforce.Live.Types

main :: IO ()
main = do
  let decode = decodeResponse . HttpResponse 200 []
      ok value check = unless (check value) (fail (show value))
  ok (decode "{\"totalSize\":1,\"done\":true,\"records\":[{\"expr0\":12345678901234567890.0123,\"nested\":{\"label\":\"hello\"}}]}") $ \value ->
    case value of
      Right (Records [Row [Field "expr0" (Number "12345678901234567890.0123"),Field "nested" (JsonValue "{\"label\":\"hello\"}")]] 1 False) -> True
      _ -> False
  ok (decodeResponse (HttpResponse 400 [] "[{\"errorCode\":\"INVALID_FIELD\",\"message\":\"Choose a valid field\"}]")) $ \value ->
    value == Right (Rejected "INVALID_FIELD" "Choose a valid field")
  ok (decodeResponse (HttpResponse 401 [] "secret-provider-body")) $ \value -> case value of Left text -> not ("secret-provider-body" `Text.isInfixOf` text); _ -> False
  ok (decode "{\"totalSize\":2,\"done\":false,\"records\":[{\"Name\":null}]}") $ \value -> value == Right (Records [Row [Field "Name" Null]] 2 True)
  let rows = Text.intercalate "," (replicate 101 "{\"x\":true}")
  ok (decode ("{\"totalSize\":101,\"done\":true,\"records\":[" <> rows <> "]}")) $ \value -> case value of Right (Records values 101 True) -> length values == 100; _ -> False
  ok (decode ("{\"totalSize\":1,\"done\":true,\"records\":[{\"x\":\"" <> Text.replicate 32769 "a" <> "\"}]}")) $ \value -> value == Right (Records [] 1 True)
  ok (decode "{\"totalSize\":42,\"done\":true,\"records\":[]}") $ \value -> value == Right (Records [] 42 False)
  ok (decode "{\"totalSize\":0,\"done\":true,\"records\":[]}") $ \value -> value == Right (Records [] 0 False)
  ok (decode "{\"totalSize\":2,\"done\":true,\"records\":[{\"Name\":null}]}") $ \value -> case value of Left _ -> True; _ -> False
  ok (decode "{\"totalSize\":0,\"done\":true,\"records\":[{\"Name\":null}]}") $ \value -> case value of Left _ -> True; _ -> False
  forM_ [400,401] $ \status -> do
    requests <- newIORef (0 :: Int)
    let handle :: (Http :+: (Secrets :+: Waiting)) a -> IO a
        handle (InLeft (SendHttp (HttpRequest _ url _ _))) = do
          modifyIORef requests (+1)
          pure (Right (if "/token" `Text.isSuffixOf` url then HttpResponse 200 [] "{\"access_token\":\"test-token\"}"
            else HttpResponse status [] "[{\"errorCode\":\"MALFORMED_QUERY\",\"message\":\"bad query\"}]"))
        handle (InRight (InLeft (GetSecret _))) = pure (Right "stored-but-revoked")
        handle _ = fail "Unexpected retry, wait or secret write"
    result <- interpretProgram handle (Live.query (LiveConfig "https://fixture.example" (Auth.ClientSecret "client" "key") "v62.0") (Soql "SELECT bad FROM Account"))
    total <- readIORef requests
    unless (total == 2) (fail "Query refusal was retried")
    unless (case (status,result) of (400,Right Rejected{}) -> True; (401,Left (FetchError _)) -> True; _ -> False)
      (fail ("Wrong query failure classification: " ++ show result))
  putStrLn "Live Salesforce response checks passed"
