module Main (main) where

import Control.Monad (forM_, unless)
import Control.Monad.Trans.State.Strict (state, evalState)
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Kyyn.Plumbing.Protocol.Frame
import Kyyn.Plumbing.Protocol.PluginHost (httpResult)
import Kyyn.Types.PluginHost
import Kyyn.Runtime.Json
import Data.Aeson (Value(..), toJSON)
import Control.Exception (SomeException, try, evaluate)
import Data.Either (isLeft)
import Kyyn.Types.Wire (parseWire)

assert :: String -> Bool -> IO ()
assert label passed = unless passed (fail label)

decode :: [B.ByteString] -> Either String (Frame,B.ByteString)
decode chunks = evalState (readFrame next B.empty) chunks
  where
    next = state $ \remaining -> case remaining of
      [] -> (Nothing,[])
      part:rest -> (Just part,rest)

fragment :: Int -> B.ByteString -> [B.ByteString]
fragment width bytes
  | B.null bytes = []
  | otherwise = let (part,rest) = B.splitAt width bytes in part : fragment width rest

main :: IO ()
main = do
  assert "distinguish absent response" (decode [] == Left "Guest exited without a response")
  assert "distinguish truncated response" (decode ["1\n"] == Left "Guest exited within a frame")
  let small = Frame (T.encodeUtf8 "{\"text\":\"雪🦋\\n\"}") (T.encodeUtf8 "body λ\n")
      wire = B.concat (encodeFrame small)
  forM_ [1 .. B.length wire - 1] $ \split ->
    assert ("split at " ++ show split) (decode [B.take split wire,B.drop split wire] == Right (small,B.empty))
  forM_ [Frame B.empty B.empty,small,Frame (B.replicate 131079 120) (T.encodeUtf8 (T.replicate 20000 "λ🦋"))] $ \frame ->
    forM_ [1,7,1024,65536,65537] $ \width ->
      assert ("fragment width " ++ show width) (decode (fragment width (B.concat (encodeFrame frame))) == Right (frame,B.empty))
  forM_ ["", "\n", "00\n", "01\nx", "-1\n", "+1\n", " 1\n", "1\r\nx", "65537\n", "999999\n", "1\n", "2\nx", "0\n", "1\nx0\n"] $ \bad ->
    assert ("reject malformed/truncated frame " ++ show bad) (case decode [bad] of Left _ -> True; _ -> False)
  assert "preserve next frame bytes" (decode [wire <> wire] == Right (small,wire))
  forM_ [200,400,401,429,503] $ \status -> do
    let (_,body) = httpResult (Right (HttpResponse status [] "provider response λ"))
    assert "all HTTP statuses retain raw body" (body == T.encodeUtf8 "provider response λ")
  let (_,failureBody) = httpResult (Left HttpTimedOut)
  assert "transport failure has empty raw body" (B.null failureBody)
  let values = [Bool True, record [], Array mempty, encodeWith textCodec "", encodeWith textCodec (T.replicate 20000 "λ\n\"\\🦋"),
        record [("a",toJSON [encodeWith stringCodec "a\tb",Bool False])],
        record [("key\nλ",record [("nested",toJSON [record [],Array mempty])])]]
  forM_ values $ \value -> assert "streamed encoding equals library encoding"
    ((T.unpack . T.decodeUtf8 . B.concat <$> printChunks value) == printValue value)
  forM_ [Null,Number 1,toJSON [Bool True,Null]] $ \value ->
    assert "streamed encoding rejects invalid profile" (case printChunks value of Left _ -> True; _ -> False)
  badString <- try (evaluate (encodeWith stringCodec "\xD800")) :: IO (Either SomeException Value)
  assert "String surrogate refused before Text.pack" (isLeft badString)
  badKey <- try (evaluate (record [("\xD800",Bool True)])) :: IO (Either SomeException Value)
  assert "String key surrogate refused before Text.pack" (isLeft badKey)
  duplicate <- try (evaluate (record [("a",Bool True),("a",Bool False)])) :: IO (Either SomeException Value)
  assert "generated duplicate fields refused" (isLeft duplicate)
  forM_ ["{\"a\":true,\"a\":false}", "{\"a\":{\"x\":true,\"x\":false}}",
         "{\"a\":true,\"\\u0061\":false}", "\"\\ud800\"", "\"\\udc00\"",
         "null", "1", "{\"x\":null}", "[true,1]", "{} trailing"] $ \input -> do
    assert ("guest rejects " ++ input) (isLeft (parseValue input))
    assert ("host rejects " ++ input) (isLeft (parseWire (T.encodeUtf8 (T.pack input))))
  assert "escaped pair decodes" (parseValue "\"\\ud83d\\ude00\"" == Right (String "😀"))
  assert "surrogate raw input refused" (isLeft (parseValue "\xD800"))
  assert "invalid UTF-8 refused" (isLeft (parseWire (B.pack [34,255,34])))
  putStrLn "Frame and bounded JSON encoding tests passed"
