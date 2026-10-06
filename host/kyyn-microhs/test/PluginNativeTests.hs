{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module PluginNativeTests (nativeTests, noNetwork, runStore) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value, object, (.=), encode, eitherDecodeStrict, toJSON)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Kyyn.Plumbing.Protocol.Frame as Wire
import Effectful (Eff, IOE, (:>), runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import qualified Effectful.State.Static.Local as State
import Kyyn.Domain.Contract (checkContract, contractId)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin (PackageIdentity(..), pluginName)
import Kyyn.Plumbing.Capability.HttpTransport (HttpTransport)
import Kyyn.Plumbing.Capability.SecretStore (SecretStore)
import Kyyn.Plumbing.Capability.PluginInteraction (Waiting)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Porcelain.Capability.EvidenceStore
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import Kyyn.Plumbing.Capability.GuestCompilation (CompiledProgram)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution(..))
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Porcelain.Protocol.PluginBroker (executeCapturedRead)
import Kyyn.Plumbing.Protocol.PluginMessages (evidenceValue)
import Kyyn.Plumbing.Capability.FileAcquisition (FileAcquisition, readSourceText)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileAcquisition (runFileAcquisitionIO)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.EvidenceAcquisition (fetchEvidence)
import Kyyn.Porcelain.Interpreter.EvidenceAcquisition (runEvidenceAcquisition)
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Domain.DataType (DataType)
import System.Directory (createDirectory, removeFile, createFileLink)
import System.FilePath ((</>))

type StoreEffects = '[EvidenceStore, DocumentPersistence, DhallHandling, FileSystem, ProcessExecution, Failure, IOE]

nativeTests :: FilePath -> FilePath -> DataType -> DataType -> CompiledProgram -> IO ()
nativeTests temporary toolchain configType payloadType program = do
  let directory = temporary </> "source-files"
      kbPath = temporary </> "kb"
  createDirectory directory
  createDirectory kbPath
  Bytes.writeFile (directory </> "same.txt") "same"
  Bytes.writeFile (directory </> "changed.txt") "old"
  Bytes.writeFile (directory </> "gone.txt") "gone"
  configContract <- right (checkContract configType (SchemaMetadata [] [] []))
  payload <- right (checkContract payloadType (SchemaMetadata [] [] []))
  kb <- right (directoryScope kbPath)
  compiler <- GuestToolchain <$> right (directoryScope toolchain)
  plugin <- right (pluginName "local-file")
  let instanceRef = ConnectorInstanceRef plugin "documents"
      package = PackageIdentity "native-test-source"
      config path = CheckedValue (contractId configContract) (object ["directory" .= path,"recursive" .= True])
      fetch path = runStore kb $ runFileAcquisitionIO $ runGuestExecution compiler $ noNetwork $ runEvidenceAcquisition $
        fetchEvidence instanceRef package payload program (config (path :: String)) Nothing Nothing
  first <- fetch directory >>= right
  let producer = EvidenceProducer package (contractId payload)
      load = runStore kb (loadCurrentEvidence instanceRef producer payload) >>= right >>= maybe (fail "Missing evidence") pure
  firstCurrent@(CurrentEvidence _ firstItems) <- load
  let firstIds = map fst firstItems
      firstOld = lookup (EvidenceId "changed.txt") firstItems
  assert "first capture lost content or fingerprint" (case firstOld of
    Just (Evidence (EvidenceFingerprint token) refs (CheckedValue _ value)) ->
      not (Text.null token) && refs == [Text.pack (directory </> "changed.txt")] && value == object ["text" .= ("old" :: String)]
    _ -> False)
  assert "first real acquisition did not publish all files"
    (firstIds == map EvidenceId ["changed.txt","gone.txt","same.txt"])
  Bytes.writeFile (directory </> "changed.txt") "changed"
  Bytes.writeFile (directory </> "new.txt") "new"
  removeFile (directory </> "gone.txt")
  second <- fetch directory >>= right
  let EvidenceSnapshotRef _ _ firstId = first
      EvidenceSnapshotRef _ _ secondId = second
  (_,summaries) <- runStore kb (listEvidenceChanges instanceRef producer payload (Just firstId)) >>= right
  assert "second real acquisition lost new/updated/removed distinctions"
    ([(kind,key) | EvidenceChangeSummary _ _ kind key _ _ <- summaries] ==
      [(Updated,EvidenceId "changed.txt"),(New,EvidenceId "new.txt"),(Removed,EvidenceId "gone.txt")])
  CurrentEvidence secondRef secondItems <- load
  assert "new invocation did not load latest contents" (secondRef == second &&
    lookup (EvidenceId "changed.txt") secondItems /= firstOld)
  assert "previously loaded invocation input changed" (case firstCurrent of
    CurrentEvidence firstRef _ -> firstRef == first)
  third <- fetch directory >>= right
  (_,unchanged) <- runStore kb (listEvidenceChanges instanceRef producer payload (Just secondId)) >>= right
  currentThird@(CurrentEvidence _ thirdItems) <- load
  assert "unchanged files emitted spurious updates" (null unchanged)
  let EvidenceSnapshotRef _ _ thirdId = third
      unchangedHead = runStore kb (evidenceHead instanceRef) >>= right
  failed <- fetch (directory </> "missing")
  assert "missing source directory published removals" (isLeft failed)
  unchangedHead >>= assert "failed acquisition moved the evidence head" . (== Just thirdId)
  Bytes.writeFile (directory </> "invalid.txt") (Bytes.pack [255,254])
  invalid <- fetch directory
  assert "invalid UTF-8 produced a partial batch" (isLeft invalid)
  unchangedHead >>= assert "failed decoding moved the evidence head" . (== Just thirdId)
  createFileLink (directory </> "same.txt") (directory </> "linked.txt")
  sourceScope <- right (directoryScope directory)
  linkPath <- right (relativePath "linked.txt")
  link <- runEff (runFileAcquisitionIO (readSourceText sourceScope linkPath))
  case link of
    Left _ -> pure ()
    Right _ -> fail "Direct text read followed a symbolic link"
  forM_
    [ "{\"tag\":\"HostRequest\",\"id\":\"1\",\"capability\":\"files\",\"method\":\"read\",\"arguments\":{\"path\":\"/file\"}}"
    , "{\"tag\":\"HostRequest\",\"id\":\"1\",\"capability\":\"evidence\",\"method\":\"list\",\"arguments\":{\"snapshot\":\"forged\"}}"
    , "{\"tag\":\"HostRequest\",\"id\":\"2\",\"capability\":\"evidence\",\"method\":\"list\",\"arguments\":{\"snapshot\":\"selected\"}}"
    , "{\"tag\":\"HostRequest\",\"id\":\"1\",\"capability\":\"unknown\",\"method\":\"list\",\"arguments\":{}}"
    ] $ \frame -> do
      let refused = runPureEff $ runFailure $ runDhallHandling $ emitFrame frame $
            executeCapturedRead program (config directory) currentThird payload
      case refused of
        Left _ -> pure ()
        Right _ -> fail "Malformed or out-of-row guest request was answered"
  saved <- maybe (fail "Missing changed evidence") pure (lookup (EvidenceId "changed.txt") thirdItems)
  let key = EvidenceId "changed.txt"
      changed = Evidence (EvidenceFingerprint "later") [] (CheckedValue (contractId payload) (object ["text" .= ("later" :: String)]))
      requests =
        [ object ["snapshot" .= ("selected" :: String)]
        , object ["snapshot" .= ("selected" :: String),"id" .= ("changed.txt" :: String)]
        , object ["snapshot" .= ("selected" :: String),"id" .= ("absent" :: String)]
        ]
      answer value = object ["tag" .= ("Right" :: String),"value" .= value]
      expected = map answer
        [ toJSON (["changed.txt","same.txt","new.txt"] :: [String])
        , object ["tag" .= ("Some" :: String),"value" .= evidenceValue saved]
        , object ["tag" .= ("None" :: String)]
        ]
      completed = object ["text" .= ("changed" :: String)]
      inspectBetween action = exchangeFrames requests expected completed action $
        executeCapturedRead program (config directory) currentThird payload
      advance = do
        result <- publishFetch instanceRef producer payload (Just thirdId) Nothing [UpdatedEvidence key changed]
        case result of Right _ -> pure (); Left problem -> error (show problem)
  stable <- runStore kb (inspectBetween advance) >>= right >>= right
  assert "captured read changed after concurrent publication" (stable == completed)
  CurrentEvidence newestRef newestItems <- load
  assert "snapshot fixture did not actually advance stored evidence"
    (newestRef /= third && lookup key newestItems == Just changed)
  let noFiles :: Eff (FileAcquisition : es) a -> Eff es a
      noFiles = interpret $ \_ _ -> error "Acquisition fixture unexpectedly read source files"
      recorded = runPureEff $ State.runState ([] :: [String]) $ runFailure $ runDhallHandling $
        noNetwork $ noFiles $ recordAcquisition firstId currentThird $
          exchangeFrames requests expected (toJSON ([] :: [Value])) (pure ()) $
            runEvidenceAcquisition (fetchEvidence instanceRef package payload program (config directory) Nothing Nothing)
      (outer,trace) = recorded
  result <- right outer >>= right
  assert "acquisition did not use one loaded input and its fetch as CAS base"
    (result == third && trace == ["head","load","publish"])
  let noEvidence :: Eff (EvidenceStore : es) a -> Eff es a
      noEvidence = interpret $ \_ _ -> error "Invalid options accessed evidence"
      noGuest :: Eff (GuestExecution : es) a -> Eff es a
      noGuest = interpret $ \_ _ -> error "Invalid options executed a guest"
  forM_ [Nothing,Just payload] $ \optionsContract -> do
    refused <- right $ runPureEff $ runFailure $ runDhallHandling $
      noNetwork $ noFiles $ noEvidence $ noGuest $ runEvidenceAcquisition
        (fetchEvidence instanceRef package payload program (config directory) optionsContract (Just "True"))
    assert "unsupported or incorrectly typed fetch options were accepted" (isLeft refused)
  putStrLn "Native acquisition: latest captured input, persisted markers, unchanged files and failure atomicity passed."

noNetwork :: Eff (HttpTransport : SecretStore : Waiting : es) a -> Eff es a
noNetwork = interpret (\_ _ -> error "Unexpected waiting") . interpret (\_ _ -> error "Unexpected secret access") . interpret (\_ _ -> error "Unexpected HTTP")

recordAcquisition :: State.State [String] :> es => FetchId -> CurrentEvidence -> Eff (EvidenceStore : es) a -> Eff es a
recordAcquisition earlier current@(CurrentEvidence snapshot@(EvidenceSnapshotRef _ _ identity) _) =
  interpret $ \_ -> \case
    EvidenceHead _ -> State.modify @[String] (++ ["head"]) >> pure (Right (Just earlier))
    LoadCurrentEvidence _ _ _ -> State.modify @[String] (++ ["load"]) >> pure (Right (Just current))
    PublishFetch _ _ _ expected _ [] | expected == Just identity ->
      State.modify @[String] (++ ["publish"]) >> pure (Right snapshot)
    _ -> error "Acquisition reopened evidence or published against a head other than its loaded input"

exchangeFrames :: [Value] -> [Value] -> Value -> Eff es () -> Eff (GuestExecution : es) a -> Eff es a
exchangeFrames requests answers result between = interpret $ \env -> \case
  ExecuteCompiled {} -> error "Plugin invocation requested one-shot execution"
  ExecuteGuest _ _ respond ->
    localSeqUnlift env $ \unlift -> do
      forM_ (zip3 [1 :: Int ..] requests answers) $ \(identity,args,answer) -> do
        let request = object ["tag" .= ("HostRequest" :: String),"id" .= show identity,
              "capability" .= ("evidence" :: String),"method" .= (if identity == 1 then "list" else "read" :: String),
              "arguments" .= args]
            expected = object ["tag" .= ("HostResponse" :: String),"id" .= show identity,"result" .= answer]
        reply <- unlift (respond (Wire.jsonFrame (Lazy.toStrict (encode request))))
        case fmap (\(Wire.Frame metadata _) -> eitherDecodeStrict metadata) reply of
          Just (Right value) | value == expected -> pure ()
          _ -> error ("Unexpected snapshot reply: " ++ show reply)
        if identity == 1 then between else pure ()
      pure (Wire.jsonFrame (Lazy.toStrict (encode (object ["tag" .= ("Completed" :: String),"result" .=
        object ["tag" .= ("Right" :: String),"value" .= result]]))),ProcessExit 0 Bytes.empty)

emitFrame :: Bytes.ByteString -> Eff (GuestExecution : es) a -> Eff es a
emitFrame frame = interpret $ \env -> \case
  ExecuteCompiled {} -> error "Plugin invocation requested one-shot execution"
  ExecuteGuest _ _ respond ->   localSeqUnlift env $ \unlift -> do
    _ <- unlift (respond (Wire.jsonFrame frame))
    pure (Wire.jsonFrame frame,ProcessExit 0 Bytes.empty)

runStore :: DirectoryScope -> Eff StoreEffects a -> IO a
runStore kb action = runEff (runFailure (runProcessExecutionIO (runFileSystemIO kb
  (runDhallHandling (runDocumentPersistenceIO $ runEvidenceStore kb action))))) >>= right

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
isLeft :: Either [Diagnostic] a -> Bool
isLeft (Left _) = True
isLeft _ = False
