{-# LANGUAGE DataKinds, GADTs, TypeApplications #-}
module ToolBrokerTests (toolBrokerTests) where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=), encode, toJSON)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import qualified Kyyn.Plumbing.Protocol.Frame as Wire
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret, reinterpret, localSeqUnlift)
import Effectful.State.Static.Local (runState, modify)
import GuestFixture (fixtureProgram)
import Kyyn.Domain.Contract (checkContract, contractId)
import Kyyn.Domain.DataType (DataType(StringType))
import Kyyn.Domain.Evidence
import Kyyn.Domain.Plugin
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution(..))
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.PluginRead (PluginRead(..))
import Kyyn.Porcelain.Protocol.ToolBroker (executeToolProgram)

toolBrokerTests :: IO ()
toolBrokerTests = do
  let contract = either (error . show) id (checkContract StringType (SchemaMetadata [] [] []))
      plugin = either error id (pluginName "files")
      instanceName = either error id (connectorName "documents")
      binding = either error id (bindingName "documents")
      kind = either error id (connectorTypeName "Folder")
      methodNameValue = either error id (methodName "content")
      program = fixtureProgram "not executed"
      method = PreparedMethod methodNameValue "Read" contract contract program
      connector = PreparedConnector kind contract contract program program [method] Nothing Nothing Nothing
      plugins = [PreparedPlugin (PreparedPackage plugin (PackageIdentity "package") [connector])
        [ConfiguredConnector instanceName binding connector (CheckedValue (contractId contract) (string "config"))]]
      snapshot = EvidenceSnapshotRef (ConnectorInstanceRef plugin "documents")
        (EvidenceProducer (PackageIdentity "package") (contractId contract)) (FetchId "captured")
      captured = CurrentEvidence snapshot [(EvidenceId "one",Evidence (EvidenceFingerprint "old") []
        (CheckedValue (contractId contract) (string "old contents")))] (FetchSummary (FetchId "captured") "2026-10-07" 1 0 0 Nothing)
      recordReads :: Eff (PluginRead : es) a -> Eff es (a,Int)
      recordReads = reinterpret (runState (0 :: Int)) $ \_ operation -> case operation of
        LoadCapturedInput {} -> error "Recipe input was reread from latest instead of its pinned capture"
        ExecuteCapturedMethod _ actual _ _ -> do
          unless (actual == captured) (error "Captured evidence changed between reads")
          modify @Int (+ 1)
          pure (Right (Right (CheckedValue (contractId contract) (string "old contents"))))
      result = runPureEff . runFailure . noModel . noJudgement . recordReads . runConversation $
        executeToolProgram program plugins Nothing [captured] (string "input")
  case result of
    Right (Right value,2) | value == string "completed" -> pure ()
    other -> fail ("Pinned conversation failed: " ++ show other)
  putStrLn "Tool broker uses supplied evidence captures for every read without loading latest."
  where string :: String -> Value
        string = toJSON

runConversation :: Eff (GuestExecution : es) a -> Eff es a
runConversation = interpret $ \env operation -> case operation of
  ExecuteCompiled {} -> error "Unexpected one-shot execution"
  ExecuteGuest _ _ respond -> localSeqUnlift env $ \unlift -> do
    mapM_ (unlift . respond . Wire.jsonFrame . frame) ["1","2"]
    pure (Wire.jsonFrame (Lazy.toStrict (encode (object ["tag" .= ("Completed" :: String),
      "result" .= object ["tag" .= ("Right" :: String),"value" .= ("completed" :: String)]]))), ProcessExit 0 "")
  where
    frame :: String -> ByteString
    frame ident = Lazy.toStrict (encode (object ["tag" .= ("HostRequest" :: String),"id" .= ident,
      "capability" .= ("plugin" :: String),"method" .= ("read" :: String),"arguments" .= object
      ["plugin" .= ("files" :: String),"connectorType" .= ("Folder" :: String),"instance" .= ("documents" :: String),
       "method" .= ("content" :: String),"input" .= ("one" :: String)]]))

noModel :: Eff (ModelTurn : es) a -> Eff es a
noModel = interpret $ \_ _ -> error "Unexpected model call"
noJudgement :: Eff (Judgement : es) a -> Eff es a
noJudgement = interpret $ \_ _ -> error "Unexpected judgement call"
