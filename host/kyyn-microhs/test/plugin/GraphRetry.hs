-- Replay safety and independent finite retry budgets, with recorded responses.
{-# LANGUAGE GADTs, TypeOperators, OverloadedStrings #-}
module KyynPluginEntry where

import Control.Monad (unless, forM_)
import Data.IORef
import Data.Either (isLeft)
import Data.Text (Text)
import Kyyn.Types.Program
import Kyyn.Types.PluginHost
import Kyyn.Types.Plugin (FetchError(..), FileRead, EvidenceRead)
import Kyyn.Types.Blob
import Kyyn.Plugin.Host (Acquisition)
import qualified MicrosoftGraph.Http as Graph

main :: IO ()
main = do
  let ok = Right (HttpResponse 200 [] "ok")
      throttle = Right (HttpResponse 429 [("Retry-After","3")] "")
      unavailable = Right (HttpResponse 503 [("retry-after","4")] "")
  (recovered,waits,sends) <- http "GET" [Left HttpTimedOut,throttle,Left HttpTimedOut,unavailable,ok]
  assert "mixed retries did not preserve both budgets" (recovered == ok && waits == [1,3,2,4] && sends == 5)
  (exhausted,_,total) <- http "GET" ([Left HttpTimedOut] ++ replicate 3 throttle ++ [Left HttpTimedOut] ++ replicate 3 throttle)
  assert "throttle budget reset by timeout" (isLeft exhausted && total == 8)
  (timed,delays,attempts) <- http "GET" [Left HttpTimedOut,throttle,Left HttpTimedOut,Left HttpTimedOut]
  assert "timeout budget reset by throttle" (isLeft timed && delays == [1,3,2] && attempts == 4)
  forM_ [Left HttpConnectionFailed,Left InvalidHttpResponse,Right (HttpResponse 429 [] ""),Right (HttpResponse 503 [("Retry-After","tomorrow")] "")] $ \response -> do
    (_,ws,n) <- http "GET" [response]
    assert "terminal response was retried" (null ws && n == 1)
  forM_ [Left HttpTimedOut,throttle,unavailable] $ \response -> do
    (_,ws,n) <- http "POST" [response]
    assert "POST was replayed" (null ws && n == 1)
  (blobResult,blobWaits,blobSends) <- blob (replicate 6 (Right (BlobResponse 429 [("Retry-After","2")] Nothing)))
  assert "blob throttle budget unbounded" (isLeft blobResult && blobWaits == replicate 5 2 && blobSends == 6)
  (failed,ws,n) <- blob [Left (FetchError "HTTP timeout in a diagnostic")]
  assert "blob error prose triggered a retry" (isLeft failed && null ws && n == 1)
  putStrLn "Graph retry budgets and replay safety passed."

http :: Text -> [Either HttpError HttpResponse] -> IO (Either Text HttpResponse,[Int],Int)
http method replies = do
  remaining <- newIORef replies
  waits <- newIORef []
  sends <- newIORef (0 :: Int)
  let handle :: (Http :+: (Secrets :+: (Waiting :+: LoginInteraction))) a -> IO a
      handle (InLeft (SendHttp _)) = modifyIORef sends (+1) >> pop remaining
      handle (InRight (InRight (InLeft (WaitSeconds n)))) = modifyIORef waits (++ [n])
      handle _ = fail "unexpected retry capability"
  result <- interpretProgram handle (Graph.send (HttpRequest method "https://fixture.test" [] ""))
  (,,) result <$> readIORef waits <*> readIORef sends

blob :: [Either FetchError BlobResponse] -> IO (Either Text (Maybe BlobRef),[Int],Int)
blob replies = do
  remaining <- newIORef replies
  waits <- newIORef []
  sends <- newIORef (0 :: Int)
  let handle :: (Http :+: (Secrets :+: (Waiting :+: (FileRead :+: (BlobAcquisition :+: (ContentDigest :+: EvidenceRead ())))))) a -> IO a
      handle (InRight (InRight (InLeft (WaitSeconds n)))) = modifyIORef waits (++ [n])
      handle (InRight (InRight (InRight (InRight (InLeft (StoreBlob _)))))) = modifyIORef sends (+1) >> pop remaining
      handle _ = fail "unexpected blob retry capability"
      program :: Acquisition () (Either Text (Maybe BlobRef))
      program = Graph.downloadOptional (BlobDownload (HttpRequest "GET" "https://fixture.test" [] "") Nothing Nothing)
  result <- interpretProgram handle program
  (,,) result <$> readIORef waits <*> readIORef sends

pop :: IORef [a] -> IO a
pop ref = do
  values <- readIORef ref
  case values of [] -> fail "Unexpected retry"; value:rest -> writeIORef ref rest >> pure value
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
