-- Actual Graph adapters under GHC/MicroHs with recording providers: auth modes,
-- polling, rotation, throttling, pagination, delta continuation and reset failures.
-- Includes 1,000 long-ID events with populated prior evidence, ordered deltas and
-- last-copy duplicate handling under the broker's per-invocation timeout.
-- No live credentials, consent or mailbox coverage.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..), FromJSON, parseJSON, object, (.=), (.:), encode, toJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (parseEither, withObject)
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString as Bytes
import qualified Data.Text.Encoding as Text
import Data.IORef (newIORef, readIORef, modifyIORef')
import Data.List (isInfixOf, isSuffixOf)
import Data.Version (showVersion)
import Effectful (runEff)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Path
import Kyyn.MicroHs.Inspection (inspectDataType, inspectPluginSignature)
import Kyyn.Domain.Plugin (PluginEntryKind(..), PluginSignature(..))
import Kyyn.Plumbing.Capability.FileSystem (readTree)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Protocol.PluginInvocation
import System.Directory (findExecutable)
import System.Environment (getEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Info (compilerVersion)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess)
import PluginFetchTests (compileBoth, Scenario(..))
import qualified PluginFetchTests as Broker

-- Provider fixtures describe HTTP responses; adapt their body to the raw section.
brokerWith :: Scenario -> (String -> String -> Value -> IO Value) -> CreateProcess -> Value
  -> IO (Maybe Value,[(String,String)],ExitCode)
brokerWith scenario respond = Broker.brokerWith scenario $ \body capability method args -> do
  enriched <- if capability == "http" then case args of
    Object fields -> do
      assert "HTTP metadata still embeds its body" (not (KeyMap.member "body" fields))
      pure (Object (KeyMap.insert "body" (String (Text.decodeUtf8 body)) fields))
    _ -> fail "Expected HTTP request object"
    else assert "Non-HTTP request carries raw body" (Bytes.null body) >> pure args
  answer <- respond capability method enriched
  pure $ case (capability,answer) of
    ("http",Object outer) | Just (Object fields) <- KeyMap.lookup "value" outer,
      Just (String contents) <- KeyMap.lookup "body" fields ->
        (Object (KeyMap.insert "value" (Object (KeyMap.delete "body" fields)) outer),Text.encodeUtf8 contents)
    _ -> (answer,Bytes.empty)

main :: IO ()
main = withSystemTempDirectory "kyyn-graph-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  compiler <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe (fail "Matching GHC required") pure
  scope <- right (directoryScope temporary)
  let load folder = do
        root <- right (directoryScope (repo </> folder))
        runEff (runFailure (runFileSystemIO scope (readTree root))) >>= right
      directories = ["shared/kyyn-types/src","guest/kyyn-sdk/src","guest/kyyn-runtime/src","vendor/json","vendor/transformers","plugins/microsoft-graph/src"]
  sources <- filter (isSuffixOf ".hs" . relativeName . fst) . concatMap files <$> mapM load directories
  let inspect name = fmap fst <$> inspectDataType toolchain (map (repo </>) directories) name >>= right
  config <- inspect "MicrosoftGraph.Types.CalendarConfig"
  payload <- inspect "MicrosoftGraph.Types.Event"
  position <- inspect "MicrosoftGraph.Types.CalendarPosition"
  (derived,_) <- inspectPluginSignature toolchain (map (repo </>) directories) AcquisitionEntry "MicrosoftGraph.Calendar.fetch" >>= right
  assert "Graph signature-derived contracts differ" (derived == StatefulFetchSignature config Nothing payload position)
  fetchSources <- right (statefulAcquisitionSources config payload Nothing position "MicrosoftGraph.Calendar.fetch" sources)
  loginAdapter <- right (loginSources config "MicrosoftGraph.Login.login" sources)
  (fetchPrograms,_) <- compileBoth temporary toolchain compiler "graph-fetch" fetchSources
  (loginPrograms,_) <- compileBoth temporary toolchain compiler "graph-login" loginAdapter
  forM_ loginPrograms $ \program -> do
    (respond,events) <- provider False
    (result,_,status) <- brokerWith Normal respond program (configuration True)
    assert "device login result" (result == Just (success (object [])) && status == ExitSuccess)
    trace <- events
    assert "device polling and refresh persistence" (filter (isInfixOf "wait:") trace == ["wait:1","wait:1","wait:6"] && "put:refresh" `elem` trace)
    (bad,_,badStatus) <- brokerWith Normal respond program (Bool True)
    assert "malformed login config executed" (bad == Nothing && badStatus /= ExitSuccess)
    (appRespond,appEvents) <- provider False
    (appResult,_,appStatus) <- brokerWith Normal appRespond program (configuration False)
    assert "application login" (appResult == Just (success (object [])) && appStatus == ExitSuccess)
    assert "application login stored token" . not . any (isInfixOf "put:") =<< appEvents
    (declinedResponder,declinedEvents) <- provider False
    let decline capability method args = if capability == "http" then do
          url <- get "url" args
          if "/token" `isInfixOf` url then pure (http 400 [] (object ["error" .= ("authorization_declined" :: String)]))
            else declinedResponder capability method args
          else declinedResponder capability method args
    (declined,_,_) <- brokerWith Normal decline program (configuration True)
    assert "declined login succeeded" (resultError declined == Right "Device login was declined.")
    assert "declined login saved credentials" . not . any (isInfixOf "put:") =<< declinedEvents
  forM_ fetchPrograms $ \program -> do
    forM_ [False,True] $ \device -> do
      (respond,events) <- provider False
      (result,_,status) <- brokerWith Normal respond program (input device none)
      assert "full delta" (status == ExitSuccess && tags result == Right ["New","Updated","Removed"])
      trace <- events
      assert "retry delay" ("wait:2" `elem` trace)
      if device then assert "refresh not persisted before Graph read"
        (take 3 trace == ["get:refresh","token:refresh_token","put:refresh"]) else pure ()
    deltaTests program
    (nullableResponder,_) <- provider False
    let nullable capability method args = if capability == "http" then do
          url <- get "url" args
          if "graph.microsoft.com" `isInfixOf` url then pure (http 200 [] (deltaPage [nullableEvent]))
            else nullableResponder capability method args
          else nullableResponder capability method args
    (nullableResult,_,_) <- brokerWith Normal nullable program (input False none)
    assert ("nullable descriptive event fields failed fetch: " ++ show nullableResult) (case tags nullableResult of Right ("Updated":_) -> True; _ -> False)
    (strictResponder,_) <- provider False
    let invalidEvent capability method args = if capability == "http" then do
          url <- get "url" args
          if "graph.microsoft.com" `isInfixOf` url then pure (http 200 [] (object ["value" .= [setField "changeKey" Null nullableEvent]]))
            else strictResponder capability method args
          else strictResponder capability method args
    (invalidEventResult,_,_) <- brokerWith Normal invalidEvent program (input False none)
    assert "invalid identity lost event context" (case resultError invalidEventResult of Right message -> "Graph event nullable:" `isInfixOf` message; _ -> False)
    (failedResponder,_) <- provider True
    (failed,_,_) <- brokerWith Normal failedResponder program (input False none)
    assert "partial page produced delta" (case failed >>= either (const Nothing) Just . parseEither (withObject "result" (.: "tag")) of Just ("Left" :: String) -> True; _ -> False)
    (invalidResponder,invalidEvents) <- provider False
    (invalid,_,_) <- brokerWith Normal invalidResponder program
      (inputConfig (setField "windowStart" (String "2026-02-30T00:00:00Z") (configuration False)) none)
    assert "invalid timestamp accepted" (tags invalid /= Right [])
    assert "invalid window caused authentication" . null =<< invalidEvents
    (throttledResponder,throttledEvents) <- provider False
    let noDelay capability method args = if capability == "http" then do
          url <- get "url" args
          if "graph.microsoft.com" `isInfixOf` url then pure (http 429 [] (object [])) else throttledResponder capability method args
          else throttledResponder capability method args
    (throttled,_,_) <- brokerWith Normal noDelay program (input False none)
    assert "missing retry delay succeeded" (case resultError throttled of Right message -> "retry later" `isInfixOf` message; _ -> False)
    assert "missing retry delay busy-looped" . not . any (isInfixOf "wait:") =<< throttledEvents
    (refreshResponder,refreshEvents) <- provider False
    let revoked capability method args = if capability == "http" then pure (http 400 [] (object ["error" .= ("invalid_grant" :: String)]))
          else refreshResponder capability method args
    (refreshFailed,_,_) <- brokerWith Normal revoked program (input True none)
    assert "revoked refresh did not request explicit login" (case resultError refreshFailed of Right message -> "run connector login" `isInfixOf` message; _ -> False)
    assert "revoked refresh changed state" . (== ["get:refresh"]) =<< refreshEvents
    forM_ [False,True] $ \duplicate -> do
      large <- scaleProvider duplicate
      (scaled,_,status) <- brokerWith Normal large program (input False none)
      assert "large calendar guest exit" (status == ExitSuccess)
      do
        changes <- maybe (fail "missing scale result") (\result -> get "value" result >>= get "changes") scaled
        actual <- mapM (\change -> do
          tag <- get "tag" change
          value <- get "value" change
          key <- if tag == ("Removed" :: String) then right (parseEither parseJSON value) else get "id" value
          pure (tag,key)) (changes :: [Value])
        let expected = [("New",scaleKey n) | n <- [if duplicate then 1002 else 1001 ..1100]] ++
              [("Updated",scaleKey n) | n <- reverse [1..100]] ++
              [("New",scaleKey 1001) | duplicate] ++
              [("Removed",scaleKey n) | n <- reverse [901..1000]]
        assert "large calendar exact delta and source/prior order" (actual == expected)
  putStrLn "Graph calendar/authentication passed under GHC and MicroHs (recording provider, no live credentials)."

deltaUrl :: String
deltaUrl = "https://graph.microsoft.com/v1.0/calendarView/delta?$deltatoken=saved"

deltaPage :: [Value] -> Value
deltaPage entries = object ["value" .= entries,"@odata.deltaLink" .= deltaUrl]

deltaTests :: CreateProcess -> IO ()
deltaTests program = do
  let prior = some (object ["deltaLink" .= deltaUrl])
      removed key = object ["id" .= (key :: String),"@removed" .= object ["reason" .= ("deleted" :: String)]]
      nextPage entries = object ["value" .= entries,"@odata.nextLink" .= ("https://graph.microsoft.com/page=2" :: String)]
      trial replies arguments = do
        (fallback,_) <- provider False
        remaining <- newIORef replies
        urls <- newIORef []
        let respond capability method args = if capability == "http" then do
              url <- get "url" args
              if "graph.microsoft.com" `isInfixOf` url then do
                modifyIORef' urls (++ [url])
                pending <- readIORef remaining
                case pending of
                  [] -> fail "unexpected additional delta request"
                  response:rest -> modifyIORef' remaining (const rest) >> pure response
                else fallback capability method args
              else if capability == "evidence" && method == "read" then do
                key <- get "id" args
                if key == ("unknown" :: String) then pure (success none) else fallback capability method args
              else fallback capability method args
        (result,_,status) <- brokerWith Normal respond program arguments
        assert "delta guest failed" (status == ExitSuccess)
        assert "delta skipped response pages" . null =<< readIORef remaining
        visited <- readIORef urls
        pure (result,visited)
  (empty,urls) <- trial [http 200 [] (deltaPage [])] (input False prior)
  assert "empty incremental fetch removed absent items" (tags empty == Right [] && urls == [deltaUrl])
  returned <- maybe (fail "missing fetch result") (\value -> get "value" value >>= get "position" >>= get "deltaLink") empty
  assert "final position lost" (returned == deltaUrl)
  (removals,_) <- trial [http 200 [] (deltaPage [removed "gone",removed "unknown"])] (input False prior)
  assert "explicit removal or unknown-ID handling wrong" (tags removals == Right ["Removed"])
  (duplicate,_) <- trial
    [http 200 [] (nextPage [event "changed" "stale" "2026-09-01T00:00:00Z"]),
     http 200 [] (deltaPage [event "changed" "latest" "2026-09-01T00:00:00Z"])] (input False prior)
  assert "duplicate delta emitted multiple changes" (tags duplicate == Right ["Updated"])
  changes <- maybe (fail "missing changes") (\value -> get "value" value >>= get "changes") duplicate
  fingerprint <- case changes :: [Value] of
    [change] -> get "value" change >>= get "evidence" >>= get "fingerprint"
    _ -> fail "expected one final duplicate"
  assert "duplicate did not choose last copy" (fingerprint == ("latest" :: String))
  (deletedLast,_) <- trial [http 200 [] (deltaPage [event "changed" "key" "2026-09-01T00:00:00Z",removed "changed"])] (input False prior)
  assert "last tombstone lost" (tags deletedLast == Right ["Removed"])
  let etagEvent = case event "changed" "unused" "2026-09-01T00:00:00Z" of
        Object fields -> Object (KeyMap.insert "@odata.etag" (String "W/\"provider-version\"") (KeyMap.delete "changeKey" fields))
        value -> value
  (etagOnly,_) <- trial [http 200 [] (deltaPage [etagEvent])] (input False prior)
  assert "delta event without changeKey was rejected" (tags etagOnly == Right ["Updated"])
  forM_ [410,404] $ \status -> do
    (reset,visited) <- trial [http status [] (object ["error" .= object ["code" .= ("syncStateNotFound" :: String)]]),
      http 200 [] (deltaPage [])] (input False prior)
    assert "expired position did not rebaseline" (tags reset == Right ["Removed","Removed","Removed"] &&
      case visited of [first,second] -> first == deltaUrl && "startDateTime=" `isInfixOf` second; _ -> False)
  (failed,_) <- trial [http 410 [] (object []),http 500 [] (object [])] (input False prior)
  assert "failed reset returned a publishable result" (case resultError failed of Right _ -> True; _ -> False)
  (continued,continuedUrls) <- trial [http 200 [] (deltaPage [])]
    (inputConfig (setField "mailbox" (String "changed@example.test") (configuration False)) prior)
  assert "configuration change discarded explicit continuation" (tags continued == Right [] && continuedUrls == [deltaUrl])

scaleKey :: Int -> String
scaleKey n = replicate 140 'A' ++ replicate (10 - length suffix) '0' ++ suffix
  where suffix = show n

scaleProvider :: Bool -> IO (String -> String -> Value -> IO Value)
scaleProvider duplicate = do
  pages <- newIORef (0 :: Int)
  let upstream = [1001..1100] ++ reverse [1..900] ++ [1001 | duplicate]
  pure $ \capability method args -> case (capability,method) of
    ("secrets","get") -> pure (success (String "synthetic"))
    ("http","send") -> do
      url <- get "url" args
      if "/token" `isInfixOf` url then pure (http 200 [] (object ["access_token" .= ("synthetic" :: String)]))
      else do
        page <- readIORef pages
        modifyIORef' pages (+1)
        let entries = take 100 (drop (page*100) upstream)
            next = ["@odata.nextLink" .= ("https://graph.microsoft.com/page/" ++ show (page+1))
              | (page+1)*100 < length upstream] ++
              ["@odata.deltaLink" .= deltaUrl | (page+1)*100 >= length upstream]
        pure (http 200 [] (object (["value" .=
          [event (scaleKey n) "current" "2026-09-01T00:00:00Z" | n <- entries]] ++ next)))
    ("evidence","list") -> pure (success (toJSON (map scaleKey (reverse [1..1000]))))
    ("evidence","read") -> do
      key <- get "id" args
      let n = read (drop 140 key) :: Int
      pure (success (if n > 1000 then none else some (object
        ["fingerprint" .= (if n <= 100 then "old" else "current" :: String),
         "references" .= ([] :: [String]), "payload" .= captured])))
    _ -> fail "unexpected scale fixture request"

configuration :: Bool -> Value
configuration device = object ["auth" .= object ["tag" .= (if device then "DeviceCode" else "ClientSecret" :: String),
  "value" .= object (["tenant" .= ("tenant" :: String),"clientId" .= ("client" :: String)] ++
    [if device then "tokenKey" .= ("refresh" :: String) else "secretKey" .= ("client-secret" :: String)])],
  "mailbox" .= ("user@example.test" :: String),"calendarId" .= none,"sharedCalendar" .= False,
  "windowStart" .= ("2026-01-01T00:00:00Z" :: String),"windowEnd" .= ("2027-01-01T00:00:00Z" :: String)]

input :: Bool -> Value -> Value
input device = inputConfig (configuration device)

inputConfig :: Value -> Value -> Value
inputConfig config prior = object ["arguments" .= object ["input" .= config,"startedAt" .= ("2026-10-07T12:00:00Z" :: String),
  "priorPosition" .= prior],"snapshot" .= ("prior" :: String)]

provider :: Bool -> IO (String -> String -> Value -> IO Value, IO [String])
provider failPage = do
  trace <- newIORef []
  polls <- newIORef (0 :: Int)
  requests <- newIORef (0 :: Int)
  let record value = modifyIORef' trace (++ [value])
      respond capability method arguments = case (capability,method) of
        ("secrets","get") -> do
          key <- get "key" arguments
          record ("get:" ++ key)
          pure (success (String "sëcret &+"))
        ("secrets","put") -> do
          key <- get "key" arguments
          value <- get "value" arguments
          assert "rotated refresh value" (value == ("new-refresh" :: String))
          record ("put:" ++ key)
          pure (object [])
        ("login","display") -> record "display" >> pure (object [])
        ("waiting","seconds") -> get "seconds" arguments >>= record . ("wait:" ++) >> pure (object [])
        ("http","send") -> do
          url <- get "url" arguments
          body <- get "body" arguments
          if "/devicecode" `isInfixOf` url then pure (http 200 [] (object
            ["device_code" .= ("device" :: String),"message" .= ("Login now" :: String),"expires_in" .= (30 :: Int),"interval" .= (1 :: Int)]))
          else if "/token" `isInfixOf` url then do
            let grant | "client_credentials" `isInfixOf` body = "client_credentials"
                      | "refresh_token" `isInfixOf` body = "refresh_token"
                      | otherwise = "device_code"
            record ("token:" ++ grant)
            if grant /= "device_code" then do
              assert "UTF-8 form escaped" ("s%C3%ABcret%20%26%2B" `isInfixOf` body)
              pure (http 200 [] token)
            else do
              modifyIORef' polls (+1)
              count <- readIORef polls
              pure (if count < 3 then http 400 [] (object ["error" .= (if count == 1 then "authorization_pending" else "slow_down" :: String)]) else http 200 [] token)
          else do
            record "graph"
            modifyIORef' requests (+1)
            count <- readIORef requests
            pure $ if count == 1 then http 429 [("Retry-After","2")] (object [])
              else if "page=2" `isInfixOf` url then if failPage then http 500 [] (object []) else http 200 [] (deltaPage [event "changed" "new-key" "2026-09-01T00:00:00Z"])
              else http 200 [] (object ["value" .= [event "new" "new-key" "2026-08-01T00:00:00Z",event "same" "same-key" "2026-08-01T00:00:00Z"],
                "@odata.nextLink" .= ("https://graph.microsoft.com/v1.0/events?page=2" :: String)])
        ("evidence","list") -> pure (success (toJSON (["same","changed","gone"] :: [String])))
        ("evidence","read") -> do
          key <- get "id" arguments
          pure (success (if key == ("new" :: String) then none else some (object
            ["fingerprint" .= (if key == "same" then "same-key" else "old-key" :: String),"references" .= ([] :: [String]),"payload" .= captured])))
        _ -> fail "Unexpected Graph request"
  pure (respond,readIORef trace)
  where
    token = object ["access_token" .= ("access" :: String),"refresh_token" .= ("new-refresh" :: String)]

captured :: Value
captured = object ["subject" .= ("Subject" :: String),"bodyPreview" .= ("Preview" :: String),"start" .= eventTime,"end" .= eventTime,
  "organizer" .= person,"attendees" .= [person],"location" .= ("Office" :: String),"isAllDay" .= False,"isCancelled" .= False,
  "eventType" .= ("singleInstance" :: String),"iCalUId" .= ("ical" :: String),"lastModifiedDateTime" .= ("2026-09-01T00:00:00Z" :: String),"webLink" .= ("https://outlook.example/event" :: String)]
eventTime :: Value
eventTime = object ["dateTime" .= ("2026-09-01T10:00:00" :: String),"timeZone" .= ("UTC" :: String)]
person :: Value
person = object ["name" .= ("Person" :: String),"address" .= ("person@example.test" :: String)]
setField :: Key.Key -> Value -> Value -> Value
setField key value (Object fields) = Object (KeyMap.insert key value fields)
setField _ _ value = value

nullableEvent :: Value
nullableEvent = foldr (uncurry setField) (event "nullable" "key" "2026-09-01T00:00:00Z")
  [("subject",Null),("bodyPreview",Null),("location",Null),("webLink",Null),("iCalUId",Null),
   ("organizer",object ["emailAddress" .= object []]),("attendees",toJSON [object ["emailAddress" .= Null]])]

event :: String -> String -> String -> Value
event key version modified = object ["id" .= key,"changeKey" .= version,"subject" .= ("Subject" :: String),"bodyPreview" .= ("Preview" :: String),
  "start" .= eventTime,"end" .= eventTime,"organizer" .= object ["emailAddress" .= person],"attendees" .= [object ["emailAddress" .= person]],
  "location" .= object ["displayName" .= ("Office" :: String)],"isAllDay" .= False,"isCancelled" .= False,
  "type" .= ("singleInstance" :: String),"iCalUId" .= ("ical" :: String),"lastModifiedDateTime" .= modified,"webLink" .= ("https://outlook.example/event" :: String)]

http :: Int -> [(String,String)] -> Value -> Value
http status headers body = success (object ["status" .= show status,
  "headers" .= [object ["name" .= n,"value" .= v] | (n,v) <- headers],"body" .= Text.decodeUtf8 (Lazy.toStrict (encode body))])
none :: Value
none = object ["tag" .= ("None" :: String)]
some :: Value -> Value
some value = object ["tag" .= ("Some" :: String),"value" .= value]
success :: Value -> Value
success value = object ["tag" .= ("Right" :: String),"value" .= value]
tags :: Maybe Value -> Either String [String]
tags Nothing = Left "No result"
tags (Just value) = parseEither (withObject "result" $ \o -> do
  tag <- o .: "tag"
  if tag /= ("Right" :: String) then fail "Fetch failed" else o .: "value" >>= withObject "fetch result"
    (\result -> result .: "changes" >>= mapM (withObject "change" (.: "tag")))) value
resultError :: Maybe Value -> Either String String
resultError Nothing = Left "No result"
resultError (Just value) = parseEither (withObject "result" $ \o -> do
  tag <- o .: "tag"
  if tag == ("Left" :: String) then o .: "value" else fail "Expected failure") value
get :: FromJSON a => String -> Value -> IO a
get key value = right (parseEither (withObject "request" (.: Key.fromString key)) value)
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)
