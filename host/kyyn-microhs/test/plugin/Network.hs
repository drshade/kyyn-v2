{-# LANGUAGE GADTs, TypeOperators, OverloadedStrings #-}
module KyynPluginEntry (main) where

import Kyyn.Plugin.Host
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Types.Program
import Kyyn.Runtime.Json
import Kyyn.Runtime.Plugin (execute, eitherCodec)
import Kyyn.Runtime.PluginHost
import Kyyn.Runtime.Transport
import qualified Data.Text as Text
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
          errors <- mapM (\problem -> sendHttp (HttpRequest "GET" ("https://fixture.test/" <> Text.pack (show problem)) [] ""))
            [HttpTimedOut,HttpConnectionFailed,HttpUnavailable]
          pure $ case response of
            Right (HttpResponse 429 [("Retry-After","2")] "response 雪")
              | errors == map Left [HttpTimedOut,HttpConnectionFailed,HttpUnavailable] -> Right "complete"
            _ -> Left (FetchError "Unexpected HTTP response")
        _ -> pure (Left (FetchError "Secret write was not visible"))
    _ -> pure (Left (FetchError "Expected a missing secret"))

handler :: Transport -> Integer -> (Calls.Http :+: (Calls.Secrets :+: (Calls.Waiting :+: Calls.LoginInteraction))) a -> IO a
handler transport identity (InLeft call) = httpRequest transport identity call
handler transport identity (InRight (InLeft call)) = secretRequest transport identity call
handler transport identity (InRight (InRight (InLeft call))) = waitingRequest transport identity call
handler transport identity (InRight (InRight (InRight call))) = loginRequest transport identity call

main :: IO ()
main = withTransport $ \transport -> readJson transport >> execute transport (eitherCodec stringCodec) (handler transport) login
