{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module PluginNativeTests (nativeTests) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value, object, (.=), encode, eitherDecodeStrict, toJSON)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Effectful (Eff, IOE, (:>), runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import qualified Effectful.State.Static.Local as State
import Kyyn.Domain.Contract (checkContract, contractId)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin (PackageIdentity(..), pluginName)
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
import Kyyn.Plumbing.Capability.FileAcquisition (readSourceText)
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
      fetch path = runStore kb $ runFileAcquisitionIO $ runGuestExecution compiler $ runEvidenceAcquisition $
        fetchEvidence instanceRef package payload program (config (path :: String))
  first <- fetch directory >>= right
  firstIds <- runStore kb (listEvidenceIds first payload) >>= right
  assert "first real acquisition did not publish all files"
    (firstIds == map EvidenceId ["changed.txt","gone.txt","same.txt"])
  Bytes.writeFile (directory </> "changed.txt") "changed"
  Bytes.writeFile (directory </> "new.txt") "new"
  removeFile (directory </> "gone.txt")
  second <- fetch directory >>= right
  let EvidenceSnapshotRef _ _ firstId = first
      EvidenceSnapshotRef _ _ secondId = second
  summaries <- runStore kb (listEvidenceChanges second payload (Just firstId)) >>= right
  assert "second real acquisition lost new/updated/removed distinctions"
    ([(kind,key) | EvidenceChangeSummary _ _ kind key _ <- summaries] ==
      [(Updated,EvidenceId "changed.txt"),(New,EvidenceId "new.txt"),(Removed,EvidenceId "gone.txt")])
  old <- runStore kb (readEvidence first payload (EvidenceId "changed.txt")) >>= right
  assert "reading historical evidence returned today's file"
    (old == Just (Evidence [directory </> "changed.txt"]
      (CheckedValue (contractId payload) (object ["text" .= ("old" :: String)]))))
  third <- fetch directory >>= right
  unchanged <- runStore kb (listEvidenceChanges third payload (Just secondId)) >>= right
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
      let refused = runPureEff $ runFailure $ runDhallHandling $ refuseStore $ emitFrame frame $
            executeCapturedRead program (config directory) payload third payload
      case refused of
        Left _ -> pure ()
        Right _ -> fail "Malformed or out-of-row guest request was answered"
  let key = EvidenceId "changed.txt"
      saved = Evidence [directory </> "changed.txt"]
        (CheckedValue (contractId payload) (object ["text" .= ("changed" :: String)]))
      changed = Evidence [] (CheckedValue (contractId payload) (object ["text" .= ("later" :: String)]))
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
        executeCapturedRead program (config directory) payload third payload
      advance = do
        let EvidenceSnapshotRef _ producer _ = third
        result <- publishFetch instanceRef producer payload (Just thirdId) [UpdatedEvidence key changed]
        case result of Right _ -> pure (); Left problem -> error (show problem)
  stable <- runStore kb (inspectBetween advance) >>= right
  assert "captured read changed after concurrent publication" (stable == completed)
  latest <- runStore kb (selectEvidence instanceRef (case third of EvidenceSnapshotRef _ producer _ -> producer) CurrentEvidence) >>= right
  newest <- runStore kb (readEvidence latest payload key) >>= right
  assert "snapshot fixture did not actually advance stored evidence" (newest == Just changed)
  let loaded = [(key,saved),(EvidenceId "same.txt",saved),(EvidenceId "new.txt",saved)]
      recorded = runPureEff $ State.runState (0 :: Int) $ runFailure $ runDhallHandling $
        snapshotStore loaded $ exchangeFrames requests expected completed (pure ()) $
          executeCapturedRead program (config directory) payload third payload
  let (outer,loads) = recorded
  readResult <- right outer
  assert "captured read loaded storage more than once" (loads == 1 && readResult == Right completed)
  putStrLn "Native acquisition: real files, persisted deltas, historical reads, unchanged files and failure atomicity passed."

snapshotStore :: State.State Int :> es => [(EvidenceId, Evidence CheckedValue)]
  -> Eff (EvidenceStore : es) a -> Eff es a
snapshotStore entries = interpret $ \_ -> \case
  LoadEvidenceSnapshot _ _ -> State.modify @Int (+ 1) >> pure (Right entries)
  _ -> error "Invocation performed a live per-item storage operation"

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
        reply <- unlift (respond (Lazy.toStrict (encode request)))
        case fmap eitherDecodeStrict reply of
          Just (Right value) | value == expected -> pure ()
          _ -> error ("Unexpected snapshot reply: " ++ show reply)
        if identity == 1 then between else pure ()
      pure (Lazy.toStrict (encode (object ["tag" .= ("Completed" :: String),"result" .=
        object ["tag" .= ("Right" :: String),"value" .= result]])),ProcessExit 0 Bytes.empty)

emitFrame :: Bytes.ByteString -> Eff (GuestExecution : es) a -> Eff es a
emitFrame frame = interpret $ \env -> \case
  ExecuteCompiled {} -> error "Plugin invocation requested one-shot execution"
  ExecuteGuest _ _ respond ->   localSeqUnlift env $ \unlift -> do
    _ <- unlift (respond frame)
    pure (frame,ProcessExit 0 Bytes.empty)

refuseStore :: Eff (EvidenceStore : es) a -> Eff es a
refuseStore = interpret $ \_ _ -> error "Invalid guest request reached evidence storage"

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
