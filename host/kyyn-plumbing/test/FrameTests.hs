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
import Text.JSON.Types

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
  let values = [JSBool True, record [], JSArray [], encodeWith textCodec "", encodeWith textCodec (T.replicate 20000 "λ\n\"\\🦋"),
        record [("a",JSArray [encodeWith stringCodec "a\tb",JSBool False]),("a",JSNull)],
        record [("key\nλ",record [("nested",JSArray [record [],JSArray []])])]]
  forM_ values $ \value -> assert "streamed encoding equals library encoding"
    ((concat <$> sequence (printChunks value)) == printValue value)
  forM_ [JSNull,JSRational False 1,encodeWith stringCodec "\xD800",JSArray [JSBool True,JSNull]] $ \value ->
    assert "streamed encoding rejects invalid profile" (case sequence (printChunks value) of Left _ -> True; _ -> False)
  putStrLn "Frame and bounded JSON encoding tests passed"
