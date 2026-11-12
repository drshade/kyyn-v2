-- Real native guest framing with recorded HTTP/evidence/secret callbacks. The
-- executable is supplied by the first-party Nix fixture; entries are selected
-- from its own description, not reconstructed names or compiler adapters.
{-# LANGUAGE OverloadedStrings #-}
module ProviderBroker (NativeProgram, nativeSource, nativeRead, nativeLogin, brokerWith, brokerRequest, Scenario(..)) where
import Control.Monad (unless)
import Data.Aeson (Value(..), eitherDecodeStrict, encode, object, (.=), (.:), toJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (parseEither, withObject)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Kyyn.Types.Guest as G
import qualified Kyyn.Plumbing.Protocol.Frame as Wire
import System.Environment (getEnv)
import System.Exit (ExitCode)
import System.IO (hFlush, hClose, hIsEOF, hGetContents, hSetBinaryMode)
import System.Process
import System.Timeout (timeout)

data NativeProgram = NativeProgram CreateProcess Text.Text

nativeSource, nativeLogin :: Text.Text -> Text.Text -> IO NativeProgram
nativeSource plugin kind = select plugin kind $ \roles -> case roles of
  G.SourceEntries _ acquisition _ _ -> [G.invocationName acquisition]
  _ -> []
nativeLogin plugin kind = select plugin kind $ \roles -> case roles of
  G.SourceEntries _ _ login _ -> maybe [] (pure . G.invocationName) login
  _ -> []
nativeRead :: Text.Text -> Text.Text -> Text.Text -> IO NativeProgram
nativeRead plugin kind method = select plugin kind $ \roles -> case roles of
  G.SourceEntries _ _ _ methods -> [G.invocationName invocation | G.CapturedEntry name _ invocation <- methods, name == method]
  _ -> []

select :: Text.Text -> Text.Text -> (G.ConnectorEntries G.DescribedContract -> [Text.Text]) -> IO NativeProgram
select plugin kind choose = do
  executable <- getEnv "KYYN_TEST_FIRST_PARTY"
  (result,_,_) <- brokerRequest Normal (\_ _ _ _ -> fail "Description invoked a host capability")
    (proc executable []) (toJSON G.Describe)
  described <- maybe (fail "No guest description") pure result
  G.GuestDescription entries _ <- right (eitherDecodeStrict (Lazy.toStrict (encode described)))
  case [entry | G.ConnectorEntry (G.ConnectorIdentity p k) roles <- entries, p == plugin, k == kind, entry <- choose roles] of
    [entry] -> pure (NativeProgram (proc executable []) entry)
    _ -> fail "Missing or duplicate provider fixture entry"

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
success :: Value -> Value
success value = object ["tag" .= ("Right" :: String),"value" .= value]

data Scenario = Normal | DirectoryFailure | FileFailure | WrongId | WrongPayload | TruncatedPayload | MissingBatchReply | ReorderedBatchReply | DuplicateBatchReply | LastBadBatchReply | TrailingBatchBody | NonCanonicalBatchLength deriving (Eq)

brokerWith :: Scenario -> (Bytes.ByteString -> String -> String -> Value -> IO (Value,Bytes.ByteString)) -> NativeProgram -> Value -> IO (Maybe Value,[(String,String)],ExitCode)
brokerWith scenario respondTo (NativeProgram program entry) input =
  brokerRequest scenario respondTo program (toJSON (G.Invoke entry input))

brokerRequest :: Scenario -> (Bytes.ByteString -> String -> String -> Value -> IO (Value,Bytes.ByteString)) -> CreateProcess -> Value -> IO (Maybe Value,[(String,String)],ExitCode)
brokerRequest scenario respondTo program input = do
  result <- timeout 20000000 $ withCreateProcess program {std_in = CreatePipe,std_out = CreatePipe,std_err = CreatePipe} $ \stdin stdout stderr process ->
    case (stdin,stdout,stderr) of
      (Just toGuest,Just fromGuest,Just errors) -> do
        hSetBinaryMode toGuest True
        hSetBinaryMode fromGuest True
        let emit value body = mapM_ (Bytes.hPut toGuest) (Wire.encodeFrame (Wire.Frame (Lazy.toStrict (encode value)) body)) >> hFlush toGuest
            next = do
              bytes <- Bytes.hGetSome fromGuest 32768
              pure (if Bytes.null bytes then Nothing else Just bytes)
            loop buffered trace = do
              done <- hIsEOF fromGuest
              if done && Bytes.null buffered then pure (Nothing,trace) else do
                (Wire.Frame metadata body,rest) <- Wire.readFrame next buffered >>= right
                message <- right (eitherDecodeStrict metadata)
                tag <- if input == toJSON G.Describe then pure "Description"
                  else right (parseEither (withObject "frame" (.: "tag")) message)
                case tag :: String of
                  "Description" -> do
                    assert "description has a raw body" (Bytes.null body)
                    pure (Just message,trace)
                  "Completed" -> do
                    assert "terminal result has a raw body" (Bytes.null body)
                    output <- right (parseEither (withObject "completed" (.: "result")) message)
                    pure (Just output,trace)
                  "HostRequest" -> do
                    (identity,capability,method,args) <- right (parseEither (withObject "request" $ \fields ->
                      (,,,) <$> fields .: "id" <*> fields .: "capability" <*> fields .: "method" <*> fields .: "arguments") message)
                    assert "request IDs are not sequential" (identity == show (length trace + 1))
                    (answer,responseBody) <- respondTo body capability method args
                    emit (object ["tag" .= ("HostResponse" :: String),"id" .=
                      (if scenario == WrongId then "wrong" else identity),"result" .=
                      (if scenario == WrongPayload then success (Bool True) else answer)]) responseBody
                    loop rest (trace ++ [(capability,method)])
                  "HostBatch" -> do
                    parts <- right (parseEither (withObject "batch" (.: "requests")) message)
                    assert "empty batch" (not (null (parts :: [Value])))
                    let respondParts _ remaining [] = do
                          assert "trailing request body" (Bytes.null remaining)
                          pure ([],[],[])
                        respondParts serial remaining (part:more) = do
                          (identity,capability,method,args,sizeText) <- right (parseEither (withObject "batch member" $ \fields ->
                            (,,,,) <$> fields .: "id" <*> fields .: "capability" <*> fields .: "method" <*> fields .: "arguments" <*> fields .: "bodyLength") part)
                          let size = read sizeText :: Int
                          assert "invalid batch body length" (size >= 0 && size <= Bytes.length remaining && show size == sizeText)
                          assert "batch IDs are not sequential" (identity == show serial)
                          let (raw,remainingBody) = Bytes.splitAt size remaining
                          (answer,responseBody) <- respondTo raw capability method args
                          (answers,bodies,calls) <- respondParts (serial+1) remainingBody more
                          pure (object ["id" .= (if scenario == WrongId then "wrong" else identity),
                            "result" .= (if scenario == WrongPayload then success (Bool True) else answer),
                            "bodyLength" .= show (Bytes.length responseBody)]:answers,responseBody:bodies,(capability,method):calls)
                    (answers,bodies,calls) <- respondParts (length trace + 1) body parts
                    let editLast key value = reverse . changeFirst key value . reverse
                        changeFirst key value (Object fields:more) = Object (KeyMap.insert key value fields):more
                        changeFirst _ _ values = values
                        changed = case scenario of
                          MissingBatchReply -> drop 1 answers
                          ReorderedBatchReply -> reverse answers
                          DuplicateBatchReply -> editLast "id" (String "1") answers
                          LastBadBatchReply -> editLast "result" (Bool True) answers
                          NonCanonicalBatchLength -> editLast "bodyLength" (String "00") answers
                          _ -> answers
                        raw = Bytes.concat bodies <> if scenario == TrailingBatchBody then "extra" else Bytes.empty
                    emit (object ["tag" .= ("HostBatchResponse" :: String),"responses" .= changed]) raw
                    loop rest (trace ++ calls)
                  _ -> fail "Unknown guest frame"
        emit input Bytes.empty
        (output,trace) <- loop Bytes.empty []
        hClose toGuest
        diagnostics <- hGetContents errors
        length diagnostics `seq` pure ()
        status <- waitForProcess process
        pure (output,trace,status)
      _ -> fail "Missing test protocol pipes"
  maybe (fail "Plugin protocol timed out") pure result

