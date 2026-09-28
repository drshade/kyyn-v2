{-# LANGUAGE GADTs, TypeOperators #-}
module KyynPluginEntry (main) where

import Kyyn.Plugin.Host
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Types.Program
import Kyyn.Runtime.Json
import Kyyn.Runtime.Plugin (execute, eitherCodec)
import Kyyn.Runtime.PluginHost
import qualified Kyyn.Types.PluginHost as Calls

login :: PluginLogin (Either FetchError String)
login = do
  missing <- getSecret "missing"
  case missing of
    Left (SecretNotFound "missing") -> do
      displayInstructions "Open the fixture URL; code 雪"
      waitSeconds 0
      putSecret "refresh" "rotated 雪"
      saved <- getSecret "refresh"
      case saved of
        Right token -> do
          response <- sendHttp (HttpRequest "POST" "https://fixture.test/token" [("Authorization",token)] "body 雪")
          errors <- mapM (\problem -> sendHttp (HttpRequest "GET" ("https://fixture.test/" ++ show problem) [] ""))
            [HttpTimedOut,HttpConnectionFailed,HttpUnavailable]
          pure $ case response of
            Right (HttpResponse 429 [("Retry-After","2")] "response 雪")
              | errors == map Left [HttpTimedOut,HttpConnectionFailed,HttpUnavailable] -> Right "complete"
            _ -> Left (FetchError "Unexpected HTTP response")
        _ -> pure (Left (FetchError "Secret write was not visible"))
    _ -> pure (Left (FetchError "Expected a missing secret"))

handler :: Integer -> (Calls.Http :+: (Calls.Secrets :+: (Calls.Waiting :+: Calls.LoginInteraction))) a -> IO a
handler identity (InLeft call) = httpRequest identity call
handler identity (InRight (InLeft call)) = secretRequest identity call
handler identity (InRight (InRight (InLeft call))) = waitingRequest identity call
handler identity (InRight (InRight (InRight call))) = loginRequest identity call

main :: IO ()
main = getLine >> execute (eitherCodec stringCodec) handler login
