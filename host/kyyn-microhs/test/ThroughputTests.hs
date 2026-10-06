-- Opt-in performance proof: cabal test guest-throughput, with KYYN_TEST_ROOT,
-- KYYN_TEST_TOOLCHAIN and MHSCPPHS set as in tools/test-guest.sh.
-- Runs the actual Graph guest, native broker and Dhall publication/reload against
-- synthetic providers; excludes compilation from the measured intervals.
{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value, object, (.=), encode)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.List (isSuffixOf, sort)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Version (showVersion)
import Effectful (Eff, IOE, (:>), runEff, liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import GHC.Clock (getMonotonicTimeNSec)
import Kyyn.Domain.Contract (checkContract, contractId)
import Kyyn.Domain.Evidence
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin (PackageIdentity(..), pluginName)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.MicroHs.Inspection (inspectDataType)
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import qualified Kyyn.Plumbing.Capability.HttpTransport as Http
import qualified Kyyn.Plumbing.Capability.SecretStore as Secrets
import qualified Kyyn.Plumbing.Capability.PluginInteraction as Interaction
import Kyyn.Plumbing.Capability.FileSystem (readTree)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.FileAcquisition (runFileAcquisitionIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Protocol.PluginInvocation (acquisitionSources)
import Kyyn.Porcelain.Capability.EvidenceAcquisition (fetchEvidence)
import Kyyn.Porcelain.Capability.EvidenceStore (loadCurrentEvidence)
import Kyyn.Porcelain.Interpreter.EvidenceAcquisition (runEvidenceAcquisition)
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import PluginFetchTests (compileBoth)
import PluginNativeTests (runStore)
import System.Directory (findExecutable, createDirectory)
import System.Environment (getEnv)
import System.FilePath ((</>))
import System.Info (compilerVersion)
import System.IO (hFlush, stdout)
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = withSystemTempDirectory "kyyn-throughput-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  ghc <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe (fail "Matching GHC required") pure
  scope <- right (directoryScope temporary)
  let directories = ["shared/kyyn-types/src","guest/kyyn-sdk/src","guest/kyyn-runtime/src",
        "vendor/json","vendor/transformers","plugins/microsoft-graph/src"]
      load directory = do
        root <- right (directoryScope (repo </> directory))
        runEff (runFailure (runFileSystemIO scope (readTree root))) >>= right
      inspect name = fmap fst <$> inspectDataType toolchain (map (repo </>) directories) name >>= right
  sources <- filter (isSuffixOf ".hs" . relativeName . fst) . concatMap files <$> mapM load directories
  configType <- inspect "MicrosoftGraph.Types.CalendarConfig"
  payloadType <- inspect "MicrosoftGraph.Types.Event"
  optionsType <- inspect "MicrosoftGraph.Types.CalendarFetch"
  adapter <- right (acquisitionSources configType payloadType (Just optionsType) "MicrosoftGraph.Calendar.fetch" sources)
  (_,program) <- compileBoth temporary toolchain ghc "graph" adapter
  config <- right (checkContract configType (SchemaMetadata [] [] []))
  payload <- right (checkContract payloadType (SchemaMetadata [] [] []))
  options <- right (checkContract optionsType (SchemaMetadata [] [] []))
  compiler <- GuestToolchain <$> right (directoryScope toolchain)
  plugin <- right (pluginName "microsoft-graph")
  forM_ [35,100] $ \pages -> do
    let folder = temporary </> show pages
        instanceRef = ConnectorInstanceRef plugin "calendar"
        package = PackageIdentity "throughput-fixture"
        producer = EvidenceProducer package (contractId payload)
    createDirectory folder
    kb <- right (directoryScope folder)
    cursor <- newIORef 0
    bodyBytes <- newIORef 0
    start <- getMonotonicTimeNSec
    outcome <- runStore kb $ runFileAcquisitionIO $ runGuestExecution compiler $
      recordHttp pages cursor bodyBytes $ recordSecrets $ recordWaiting $ runEvidenceAcquisition $
        fetchEvidence instanceRef package payload program (CheckedValue (contractId config) configuration) (Just options) Nothing
    _ <- right outcome
    published <- getMonotonicTimeNSec
    current <- runStore kb (loadCurrentEvidence instanceRef producer payload) >>= right >>= maybe (fail "No published capture") pure
    let CurrentEvidence _ items = current
    unless (length items == pages * 100) (fail "Published evidence count differs")
    unless (sort [key | (EvidenceId key,_) <- items] == sort [itemId n | n <- [1 .. pages*100]]) (fail "Published IDs differ")
    forM_ items $ \(_,Evidence fingerprint _ (CheckedValue _ value)) ->
      unless (fingerprint == EvidenceFingerprint "version" && value == captured)
        (fail "Published Dhall payload differs from provider evidence")
    verified <- getMonotonicTimeNSec
    total <- readIORef bodyBytes
    let seconds a b = fromIntegral (b-a) / 1000000000 :: Double
    putStrLn ("THROUGHPUT " ++ show (object ["pages" .= pages,"records" .= length items,"httpBodyBytes" .= total,
      "acquireAndPublishSeconds" .= seconds start published,"reloadAndVerifySeconds" .= seconds published verified]))
    hFlush stdout

recordSecrets :: Eff (Secrets.SecretStore : es) a -> Eff es a
recordSecrets = interpret $ \_ -> \case
  Secrets.ReadSecret _ -> pure (Right "synthetic-token")
  _ -> error "Unexpected secret mutation"

recordWaiting :: Eff (Interaction.Waiting : es) a -> Eff es a
recordWaiting = interpret $ \_ _ -> error "Unexpected retry"

recordHttp :: IOE :> es => Int -> IORef Int -> IORef Int -> Eff (Http.HttpTransport : es) a -> Eff es a
recordHttp total cursor bytes = interpret $ \_ (Http.SendHttp (Http.HttpRequest _ url _ _)) -> do
  value <- if "login.microsoftonline.com" `Text.isInfixOf` url
    then pure (object ["access_token" .= ("synthetic" :: Text.Text)]) else do
      page <- liftIO (readIORef cursor)
      unless (page < total) (error "Unexpected extra provider request")
      liftIO (modifyIORef' cursor (+1))
      pure (object (["value" .= [event n | n <- [page*100+1 .. (page+1)*100]]] ++
        ["@odata.nextLink" .= ("https://graph.microsoft.com/page/" <> Text.pack (show (page+1))) | page+1 < total]))
  let body = Lazy.toStrict (encode value)
  liftIO (modifyIORef' bytes (+ Bytes.length body))
  pure (Right (Http.HttpResponse 200 [] (Text.decodeUtf8 body)))

configuration :: Value
configuration = object ["auth" .= object ["tag" .= ("ClientSecret" :: Text.Text),"value" .= object
  ["tenant" .= ("fixture" :: Text.Text),"clientId" .= ("fixture" :: Text.Text),"secretKey" .= ("fixture" :: Text.Text)]],
  "mailbox" .= ("fixture@example.invalid" :: Text.Text),"calendarId" .= object ["tag" .= ("None" :: Text.Text)],"sharedCalendar" .= False]

itemId :: Int -> Text.Text
itemId n = "event-" <> Text.pack (show n)

preview :: Text.Text
preview = Text.replicate 300 "text λ "

event :: Int -> Value
event n = object ["id" .= itemId n,"changeKey" .= ("version" :: Text.Text),"subject" .= ("Subject" :: Text.Text),
  "bodyPreview" .= preview,"start" .= eventTime,"end" .= eventTime,"organizer" .= object ["emailAddress" .= person],
  "attendees" .= ([] :: [Value]),"location" .= object ["displayName" .= ("Office" :: Text.Text)],
  "isAllDay" .= False,"isCancelled" .= False,"type" .= ("singleInstance" :: Text.Text),"iCalUId" .= ("ical" :: Text.Text),
  "lastModifiedDateTime" .= ("2026-09-01T00:00:00Z" :: Text.Text),"webLink" .= ("https://fixture.invalid/event" :: Text.Text)]

captured :: Value
captured = object ["subject" .= ("Subject" :: Text.Text),"bodyPreview" .= preview,"start" .= eventTime,"end" .= eventTime,
  "organizer" .= person,"attendees" .= ([] :: [Value]),"location" .= ("Office" :: Text.Text),"isAllDay" .= False,"isCancelled" .= False,
  "eventType" .= ("singleInstance" :: Text.Text),"iCalUId" .= ("ical" :: Text.Text),
  "lastModifiedDateTime" .= ("2026-09-01T00:00:00Z" :: Text.Text),"webLink" .= ("https://fixture.invalid/event" :: Text.Text)]

eventTime :: Value
eventTime = object ["dateTime" .= ("2026-09-01T00:00:00Z" :: Text.Text),"timeZone" .= ("UTC" :: Text.Text)]

person :: Value
person = object ["name" .= ("Person" :: Text.Text),"address" .= ("person@example.invalid" :: Text.Text)]

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
