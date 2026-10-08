{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module ToolTests (testTools) where

import Control.Monad (unless, forM_)
import Data.Aeson (toJSON, object, (.=), encode)
import qualified Data.ByteString.Lazy as Lazy
import Data.List (isInfixOf)
import qualified Data.ByteString as Bytes
import qualified Kyyn.Plumbing.Protocol.Frame as Wire
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Version (showVersion)
import Effectful (Eff, runEff, runPureEff, (:>))
import Effectful.Dispatch.Dynamic (interpret, reinterpret, localSeqUnlift)
import Effectful.State.Static.Local (runState, modify)
import Kyyn.Domain.Contract (contractId)
import Kyyn.Domain.DataType (DataType(..))
import Kyyn.Domain.Plugin (pluginName, connectorTypeName, connectorName, methodName, bindingName)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..))
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Path (DirectoryScope, scopePath, relativePath, relativeName)
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.MicroHs.Toolchain (GuestToolchain)
import Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation)
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.MicroHs.Interpreter.SchemaInspection (runSchemaInspectionIO)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation(..), compileGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution(..))
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, sourceFiles, selectedEntry)
import Kyyn.Plumbing.Protocol.Tool (ConnectorInterface(..), InstanceBinding(..), toolSources, decodeToolFrame)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.KnowledgeBaseInitialization (initialRootFiles)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.PluginRead (PluginRead(..), loadCapturedInput, executeCapturedMethod, resolveCapturedBlobs)
import Kyyn.Porcelain.Capability.EvidenceStore (clearEvidence)
import Kyyn.Porcelain.Capability.Tool
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Plumbing.Interpreter.BlobStorage (runBlobStorageIO)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.ToolExecution (runToolExecution)
import System.Directory (createDirectoryIfMissing, findExecutable)
import System.FilePath ((</>), takeDirectory, takeBaseName)
import System.Exit (ExitCode(..))
import System.Info (compilerVersion)
import System.Process (readProcessWithExitCode)

noJudgement :: Eff (Judgement : es) a -> Eff es a
noJudgement = interpret $ \_ _ -> error "Captured-read fixture unexpectedly requested judgement"

noModel :: Eff (ModelTurn : es) a -> Eff es a
noModel = interpret $ \_ _ -> error "Captured-read fixture unexpectedly requested a model"

testTools :: DirectoryScope -> GuestToolchain -> FileTree -> FileTree -> [PreparedPlugin] -> IO ()
testTools scope toolchain sdk pluginCode plugins = do
  testBindingShapes scope toolchain sdk
  initial <- right initialRootFiles
  helperPath <- right (relativePath "src/Helpers.hs")
  let helper = Text.encodeUtf8 (Text.unlines
        [ "module Helpers where"
        , "import Data.Text (Text)"
        , "import Kyyn.Plugin (FetchError)"
        , "import Kyyn.Plugin (Evidence(..), EvidenceId(..))"
        , "import Kyyn.Connectors (Tool)"
        , "import qualified Kyyn.Connectors as Connectors"
        , "import qualified Kyyn.Plugins.P_local_file.Folder as Files"
        , "import qualified Kyyn.Plugins.P_local_file.Folder.Evidence as Evidence"
        , "type Input = [Text]"
        , "type Output = [Text]"
        , "bulk :: Input -> Tool (Either FetchError Output)"
        , "bulk ids = do"
        , "  keys <- Evidence.listEvidenceIds Connectors.salesFiles"
        , "  found <- Evidence.readEvidence Connectors.salesFiles (EvidenceId \"one.txt\")"
        , "  absent <- Evidence.readEvidence Connectors.salesFiles (EvidenceId \"absent.txt\")"
        , "  a <- mapM (Files.content Connectors.salesFiles) ids"
        , "  b <- mapM (Files.content Connectors.supportFiles) ids"
        , "  missing <- Files.content Connectors.salesFiles \"absent.txt\""
        , "  pure $ case (keys,found,absent,missing) of"
        , "    (Right current,Right (Just (Evidence _ refs _)),Right Nothing,Left _)"
        , "      | EvidenceId \"one.txt\" `elem` current && not (null refs) -> sequence (a ++ b)"
        , "    _ -> Right []"
        ])
      declaration = "[{ name = \"bulk\", description = \"Read both folders\", implementation = \"Helpers.bulk\", inputType = \"Helpers.Input\", resultType = \"Helpers.Output\" }]"
      empty = "[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }"
      manifest (path,bytes) | relativeName path == "kb.dhall" = (path,Text.encodeUtf8 (Text.replace empty declaration (Text.decodeUtf8 bytes)))
                            | otherwise = (path,bytes)
  code <- right (fileTree (map manifest (files initial) ++ files pluginCode ++ [(helperPath,helper)]))
  (prepared,sources) <- runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope (runDhallHandling
    (runGuestExecution toolchain (runGuestCompilation toolchain Nothing (runSchemaInspectionIO toolchain Nothing (runRootStore
      (captureCompilation (runToolPreparation sdk (prepareTools code plugins))))))))))) >>= right
  tools <- right prepared
  forM_ sources $ \source -> compileGhc scope source True
  selected@(PreparedTool (ToolDescriptor _ _ _ result) _ _ _) <- case tools of
    [one] -> pure one
    _ -> fail "Expected the registered bulk tool"
  forM_ [("absent","Folder","content"),("sales","Other","content"),("sales","Folder","absent")] $ \(instanceName,kind,method) -> do
    let frame = Lazy.toStrict (encode (object ["tag" .= ("HostRequest" :: String), "id" .= ("1" :: String),
          "capability" .= ("plugin" :: String), "method" .= ("read" :: String),
          "arguments" .= object ["plugin" .= ("local-file" :: String), "instance" .= (instanceName :: String),
            "connectorType" .= (kind :: String), "method" .= (method :: String), "input" .= ("one.txt" :: String)]]))
        response = runPureEff (runFailure (runDhallHandling (emitFrame frame (noReads
          ((noJudgement . noModel . runToolExecution) (executeTool selected (toJSON (["one.txt"] :: [String]))))))))
    assert "Impossible generated request became a user diagnostic" (case response of
      Left (RuntimeUnavailable (ProcessDiagnostic ReadOutput _)) -> True
      _ -> False)
  let invoke input = runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope (runDhallHandling
        (runGuestExecution toolchain (runDocumentPersistenceIO ((runBlobStorageIO scope . runEvidenceStore scope) (runPluginRead
          (countReads ((noJudgement . noModel . runToolExecution) (executeTool selected input))))))))))) >>= right
  (response,loads) <- invoke (toJSON (["one.txt","one.txt"] :: [String]))
  value <- right response
  assert "Tool did not compose instances or catch the typed missing-ID failure"
    (value == (CheckedValue (contractId result) (toJSON (replicate 4 ("one" :: String))),[]))
  assert "Repeated calls reloaded captured input" (map (\(ConnectorInstanceRef _ name) -> name) loads == ["support","sales"])
  (invalid,invalidLoads) <- invoke (toJSON True)
  assert "Tool accepted an invalid argument" (case invalid of Left _ -> True; Right _ -> False)
  assert "Invalid argument read evidence" (null invalidLoads)
  case plugins of
    [PreparedPlugin (PreparedPackage plugin _ _) _] -> do
      _ <- runEff (runFailure (runFileSystemIO scope (runDhallHandling (runDocumentPersistenceIO
        ((runBlobStorageIO scope . runEvidenceStore scope) (clearEvidence (ConnectorInstanceRef plugin "sales"))))))) >>= right
      (absent,_) <- invoke (toJSON (["one.txt"] :: [String]))
      assert "Missing capture was catchable or lost instance context" (case absent of
        Left diagnostics -> any (\(Diagnostic _ name message _) -> name == "evidence.not-fetched" && "local-file/sales" `isInfixOf` Text.unpack message) diagnostics
        Right _ -> False)
    _ -> fail "Expected local-file plugin in helper fixture"
  putStrLn "KB tools: generated proxies compiled in GHC/MicroHs; two-instance composition and catchable missing evidence passed."

captureCompilation :: GuestCompilation :> es => Eff (GuestCompilation : es) a -> Eff es (a,[GuestSources])
captureCompilation = reinterpret (runState []) $ \_ (CompileGuest sources) -> do
  modify (sources :)
  compileGuest sources

countReads :: PluginRead :> es => Eff (PluginRead : es) a -> Eff es (a,[ConnectorInstanceRef])
countReads = reinterpret (runState []) $ \_ operation -> case operation of
  LoadCapturedInput instanceRef producer payload -> do
    modify (instanceRef :)
    loadCapturedInput instanceRef producer payload
  ExecuteCapturedMethod payload current method value -> executeCapturedMethod payload current method value
  ResolveCapturedBlobs contexts contract value -> resolveCapturedBlobs contexts contract value

noReads :: Eff (PluginRead : es) a -> Eff es a
noReads = interpret $ \_ _ -> error "Impossible generated request reached captured input"

emitFrame :: Bytes.ByteString -> Eff (GuestExecution : es) a -> Eff es a
emitFrame frame = interpret $ \env operation -> case operation of
  ExecuteCompiled {} -> error "Tool unexpectedly requested one-shot execution"
  ExecuteGuest _ _ respond -> localSeqUnlift env $ \unlift -> do
    _ <- unlift (respond (Wire.jsonFrame frame))
    pure (Wire.jsonFrame frame,ProcessExit 0 Bytes.empty)

testBindingShapes :: DirectoryScope -> GuestToolchain -> FileTree -> IO ()
testBindingShapes scope toolchain sdk = do
  path <- right (relativePath "Probe.hs")
  let source body = (path,Text.encodeUtf8 (Text.pack body))
      compile sources = runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope
        (runGuestCompilation toolchain Nothing (compileGuest sources))))) >>= right
  empty <- right (toolSources [] [] StringType StringType "Probe.helper" (files sdk ++ [source
    "module Probe where\nhelper x = pure (Right x)\n"]))
  compileGhc scope empty True
  _ <- compile empty >>= right
  plugin <- right (pluginName "sample")
  folder <- right (connectorTypeName "Folder")
  other <- right (connectorTypeName "Other")
  method <- right (methodName "request")
  name <- right (connectorName "other")
  binding <- right (bindingName "other")
  let proxy selectedKind = toolSources [ConnectorInterface plugin folder StringType [(method,StringType,StringType)], ConnectorInterface plugin other StringType []]
        [InstanceBinding binding plugin selectedKind name] StringType StringType "Probe.helper" (files sdk ++ [source
          "module Probe where\nimport qualified Kyyn.Connectors as C\nimport qualified Kyyn.Plugins.P_sample.Folder as F\nhelper x = F.request C.other x\n"])
  matching <- right (proxy folder)
  compileGhc scope matching True
  _ <- compile matching >>= right
  wrong <- right (proxy other)
  compileGhc scope wrong False
  refused <- compile wrong
  assert "MicroHs allowed a different connector type's instance" (case refused of Left _ -> True; Right _ -> False)
  forM_ ["{\"tag\":\"HostRequest\",\"id\":\"1\",\"capability\":\"files\",\"method\":\"read\",\"arguments\":{}}",
    "{\"tag\":\"HostRequest\",\"id\":\"1\",\"capability\":\"plugin\",\"method\":\"read\",\"arguments\":{\"plugin\":\"sample\"}}"] $ \frame ->
    assert "Malformed or out-of-row tool request was accepted" (case decodeToolFrame frame of Left _ -> True; Right _ -> False)

compileGhc :: DirectoryScope -> GuestSources -> Bool -> IO ()
compileGhc scope sources expected = do
  let directory = scopePath scope </> "ghc-tool"
  ghc <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe (fail "Missing matching GHC") pure
  forM_ (sourceFiles sources) $ \(path,bytes) -> do
    let target = directory </> relativeName path
    createDirectoryIfMissing True (takeDirectory target)
    let agentic = take 8 (relativeName path) == "Agentic/" || relativeName path == "Agentic.hs"
        extensions = "{-# LANGUAGE DuplicateRecordFields, NoFieldSelectors, OverloadedRecordDot #-}\n"
    Bytes.writeFile target (if agentic then extensions <> bytes else bytes)
  (status,out,err) <- readProcessWithExitCode ghc ["-v0","-XGHC2021","-XDataKinds","-XDefaultSignatures","-XDeriveAnyClass",
    "-XDerivingVia","-XGADTs","-XLambdaCase","-XOverloadedStrings","-XRankNTypes","-fno-code","-i" ++ directory,
    "-outputdir",directory </> "objects","-main-is",takeBaseName (relativeName (selectedEntry sources)) ++ ".main",
    directory </> relativeName (selectedEntry sources)] ""
  assert ("Unexpected GHC result for generated helper: " ++ out ++ err) ((status == ExitSuccess) == expected)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
