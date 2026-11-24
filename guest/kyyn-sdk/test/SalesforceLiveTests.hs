-- Provider-free response tests for bounded live SOQL; replay is an installed journey.
module Main where

import Control.Monad (unless)
import qualified Data.Text as Text
import Salesforce.Live (decodeResponse)
import Salesforce.Live.Types
import Kyyn.Plugin.Host (HttpResponse(..))

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
  ok (decode "{\"totalSize\":2,\"done\":true,\"records\":[]}") $ \value -> case value of Left _ -> True; _ -> False
  putStrLn "Live Salesforce response checks passed"
