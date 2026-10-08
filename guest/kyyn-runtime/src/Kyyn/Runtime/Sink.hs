{-# LANGUAGE GADTs #-}
module Kyyn.Runtime.Sink (executeSink, sinkResultCodec) where

import Kyyn.Types.Sink
import Kyyn.Types.Program (Program)
import Kyyn.Runtime.Json
import Kyyn.Runtime.Transport
import Kyyn.Runtime.Plugin (execute, exchange)

sinkResultCodec :: Codec a -> Codec (Either SinkError a)
sinkResultCodec value = Codec enc dec
  where
    enc (Right result) = record [("tag",encodeWith stringCodec "Right"),("value",encodeWith value result)]
    enc (Left problem) = record [("tag",encodeWith stringCodec "Left"),("value",errorValue problem)]
    errorValue problem = let (kind,message) = case problem of
                              SinkRejected m -> ("Rejected",m)
                              SinkUncertain m -> ("Uncertain",m)
      in record [("kind",encodeWith stringCodec kind),("message",encodeWith textCodec message)]
    dec input = do
      members <- fields ["tag","value"] input
      tag <- field "tag" stringCodec members
      case tag of
        "Right" -> Right <$> field "value" value members
        "Left" -> do
          problem <- field "value" (Codec id Right) members
          details <- fields ["kind","message"] problem
          kind <- field "kind" stringCodec details
          message <- field "message" textCodec details
          case kind of
            "Rejected" -> pure (Left (SinkRejected message))
            "Uncertain" -> pure (Left (SinkUncertain message))
            _ -> Left "Unknown sink error"
        _ -> Left "Invalid sink result"

executeSink :: Codec config -> Codec options -> Codec input -> Codec result -> options
  -> (config -> options -> input -> Program SinkCalls (Either SinkError result)) -> IO ()
executeSink configCodec optionsCodec inputCodec resultCodec defaults publish = withTransport $ \transport -> do
  request <- readJson transport >>= either fail pure . parseValue
  case decodeWith stringCodec request of
    Right "Defaults" -> either fail (writeJson transport) (printValue (encodeWith optionsCodec defaults))
    _ -> do
      members <- either fail pure (fields ["config","options","input"] request)
      config <- either fail pure (field "config" configCodec members)
      options <- either fail pure (field "options" optionsCodec members)
      input <- either fail pure (field "input" inputCodec members)
      execute transport (sinkResultCodec resultCodec) (handler transport) (publish config options input)
  where
    handler :: Transport -> Integer -> FileWrite a -> IO a
    handler transport identity (WriteTextFile path content) = exchange transport identity "files" "write"
      (record [("path",encodeWith stringCodec path),("content",encodeWith textCodec content)]) (sinkResultCodec stringCodec)
