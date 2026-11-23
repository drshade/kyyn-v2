{-# LANGUAGE OverloadedStrings #-}
-- Event envelopes and the real subprocess HTTP transport. No provider is contacted.
module EventTests (check, guest) where

import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=), encode, eitherDecodeStrict')
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Aeson.KeyMap as Keys
import Data.Either (isLeft)
import Data.Functor.Identity (runIdentity)
import System.Exit (ExitCode(..))
import qualified System.Process.Typed as Process
import Kyyn.Plugin.Event
import Kyyn.Plugin.Host (sendHttp, HttpRequest(..), HttpResponse(..))
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Runtime.Event
import Kyyn.Runtime.Json
import Kyyn.Runtime.Transport (withTransport)
import qualified Kyyn.Plumbing.Protocol.Frame as Frame

guest :: IO ()
guest = withTransport $ \transport -> executeEventAction transport (batchCodec textCodec integerCodec) $ do
  response <- sendHttp (HttpRequest "GET" "https://synthetic.invalid/events" [] "")
  pure $ case response of
    Left _ -> Left (FetchError "provider unavailable")
    Right (HttpResponse _ _ body) -> Right (EventBatch [EventArrival (EventIdentity "provider-1") body] 7)

check :: FilePath -> IO ()
check executable = do
  let poll = pollCodec textCodec integerCodec
      batch = batchCodec textCodec integerCodec
      roundtrip codec value = decodeWith codec (encodeWith codec value) == Right value
  expect "dispatch envelope" (roundtrip (dispatchCodec textCodec) (EventDispatch (WaitId "wait-1") "question"))
  expect "initial poll" (roundtrip poll (EventPoll (WaitId "wait-1") "question" Nothing))
  expect "resumed poll" (roundtrip poll (EventPoll (WaitId "wait-1") "question" (Just 123456789012345678901234567890)))
  expect "duplicate arrivals preserved for host classification" (roundtrip batch
    (EventBatch [EventArrival (EventIdentity "same") "one",EventArrival (EventIdentity "same") "two"] 3))
  expect "empty batch advances cursor" (roundtrip batch (EventBatch [] 4))
  expect "malformed reply rejected" (isLeft (decodeWith batch (object
    ["arrivals" .= [object ["identity" .= String "x","value" .= True]],"cursor" .= String "4"])))
  expect "malformed cursor rejected" (isLeft (decodeWith batch (object
    ["arrivals" .= [object ["identity" .= String "x","value" .= String "valid"]],"cursor" .= True])))
  let extra codec value = case encodeWith codec value of
        Object fields -> isLeft (decodeWith codec (Object (Keys.insert "extra" (String "unexpected") fields)))
        _ -> False
  expect "strict dispatch fields" (extra (dispatchCodec textCodec) (EventDispatch (WaitId "w") "q"))
  expect "strict poll fields" (extra poll (EventPoll (WaitId "w") "q" Nothing))
  expect "strict batch fields" (extra batch (EventBatch [] 0))
  expect "strict arrival fields" (isLeft (decodeWith batch (object
    ["arrivals" .= [object ["identity" .= String "x","value" .= String "valid","extra" .= String "unexpected"]],"cursor" .= String "4"])))
  expect "missing cursor rejected" (isLeft (decodeWith poll (object
    ["waitIdentity" .= String "wait-1","request" .= String "question"])))
  let result = object ["tag" .= String "Right","value" .= object ["status" .= String "200","headers" .= ([] :: [Value])]]
      acknowledgement = object ["tag" .= String "HostResponse","id" .= String "1","result" .= result]
      input = Frame.Frame (Lazy.toStrict (encode acknowledgement)) "hello"
  (status,output,errors) <- Process.readProcess (Process.setStdin
    (Process.byteStringInput (Lazy.fromStrict (Bytes.concat (Frame.encodeFrame input))))
    (Process.proc executable ["--event-guest"]))
  unless (status == ExitSuccess) (fail (show errors))
  (Frame.Frame request body,rest) <- right (runIdentity (Frame.readFrame (pure Nothing) (Lazy.toStrict output)))
  requestValue <- right (eitherDecodeStrict' request)
  expect "HTTP broker request" (requestValue == object
    ["tag" .= String "HostRequest","id" .= String "1","capability" .= String "http","method" .= String "send",
     "arguments" .= object ["method" .= String "GET","url" .= String "https://synthetic.invalid/events","headers" .= ([] :: [Value])]])
  expect "empty GET body" (Bytes.null body)
  (Frame.Frame completed raw,remaining) <- right (runIdentity (Frame.readFrame (pure Nothing) rest))
  completedValue <- right (eitherDecodeStrict' completed)
  expect "typed batch completion" (completedValue == object ["tag" .= String "Completed","result" .= object
    ["tag" .= String "Right","value" .= encodeWith batch (EventBatch [EventArrival (EventIdentity "provider-1") "hello"] 7)]])
  expect "no trailing transport bytes" (Bytes.null raw && Bytes.null remaining)
  putStrLn "Event envelopes and synthetic HTTP transport passed."
  where
    expect label ok = unless ok (fail label)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
