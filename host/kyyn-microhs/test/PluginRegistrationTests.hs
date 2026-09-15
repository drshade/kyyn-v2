{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Data.List (isInfixOf, stripPrefix)
import Data.Version (showVersion)
import Data.Coerce (coerce)
import Kyyn.Domain.Plugin (ConnectorTypeName(..), ConnectorName(..), MethodName(..), PackageIdentity(..))
import Data.Aeson (Value, encode, object, (.=), toJSON)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, IOE, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (ValidationReport(..), Diagnostic(..), Severity(..), CheckResult(..))
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Contract (rootType, contractId)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Domain.Path (DirectoryScope, directoryScope, relativePath, relativeName)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), CurrentEvidence(..), EvidenceProducer(..))
import Kyyn.Domain.GuestApi (ApiModule(..), ApiSymbol(..), Namespace(..))
import Kyyn.MicroHs.ApiInspection (inspectApi)
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation)
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.MicroHs.Interpreter.SchemaInspection (runSchemaInspectionIO)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem, readTree)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, sourceFiles, selectedEntry)
import Kyyn.Plumbing.Protocol.PluginInvocation (acquisitionSources, capturedReadSources)
import Kyyn.Plumbing.Capability.Git (Git)
import Kyyn.Porcelain.Capability.EvidenceStore (loadCurrentEvidence)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileAcquisition (runFileAcquisitionIO)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Protocol.PluginRegistration (decodeConnectors)
import Kyyn.Plumbing.Protocol.ConnectorConfig (decodeInstances)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Capability.PluginRead (callCapturedMethod)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import Kyyn.Porcelain.Capability.EvidenceAcquisition (fetchEvidence)
import Kyyn.Porcelain.Interpreter.EvidenceAcquisition (runEvidenceAcquisition)
import Kyyn.Porcelain.Capability.KnowledgeBaseInitialization (initialRootFiles)
import Kyyn.Porcelain.Capability.RootOpening (openCapturedRoot)
import Kyyn.Porcelain.Capability.Validation (checkRoot)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import System.Directory (createDirectory, createDirectoryIfMissing, findExecutable)
import System.Environment (getEnv)
import System.FilePath ((</>), takeDirectory)
import System.Exit (ExitCode(..))
import System.Info (compilerVersion)
import System.Process (readProcessWithExitCode)
import System.IO.Temp (withSystemTempDirectory)

type Preparation = '[PluginPreparation, SchemaInspection, GuestCompilation, GuestExecution, DhallHandling, FileSystem, ProcessExecution, Failure, IOE]

main :: IO ()
main = withSystemTempDirectory "kyyn-registration-" $ \temporary -> do
  let declaration name = withMethods name []
      withMethods name methods = object ["name" .= (name :: String),"configType" .= ("LocalFile.Types.FolderConfig" :: String),
        "payloadType" .= ("LocalFile.Types.Document" :: String),"fetch" .= ("LocalFile.Folder.fetch" :: String),
        "validateConfig" .= ("LocalFile.Config.validate" :: String), "methods" .= (methods :: [Value])]
      methodValue name input = object ["name" .= (name :: String),"description" .= ("Read text" :: String),
        "inputType" .= (input :: String),"resultType" .= ("LocalFile.Types.Content" :: String),
        "implementation" .= ("LocalFile.Read.content" :: String)]
      rejected :: Either e a -> Bool
      rejected (Left _) = True
      rejected _ = False
  forM_ [[declaration "Folder",declaration "Folder"],[declaration "folder"],[object ["name" .= ("Folder" :: String)]]] $
    \value -> assert "Invalid connector registration accepted" (rejected (decodeConnectors (Lazy.toStrict (encode value))))
  let validMethod = methodValue "content" "LocalFile.Types.ContentId"
  forM_ [[validMethod,validMethod],[methodValue "case" "LocalFile.Types.ContentId"],[methodValue "content" "String"]] $ \methods ->
    assert "Invalid method registration accepted" (case decodeConnectors (Lazy.toStrict (encode [withMethods "Folder" methods])) of
      Left message -> "Folder" `isInfixOf` message
      Right _ -> False)
  let instanceValue name binding = object ["name" .= (name :: String),"binding" .= (binding :: String),
        "connector" .= object ["tag" .= ("Folder" :: String),"value" .= object []]]
  forM_ [[instanceValue "same" "a",instanceValue "same" "b"],[instanceValue "one" "case"],
      [instanceValue "" "a"],[instanceValue "one" "Uppercase"]] $ \values ->
    assert "Invalid instance configuration accepted" (rejected (decodeInstances (toJSON values)))
  repo <- getEnv "KYYN_TEST_ROOT"
  runtime <- getEnv "KYYN_TEST_TOOLCHAIN"
  api <- inspectApi runtime (map (repo </>) ["shared/kyyn-types/src","guest/kyyn-sdk/src"]) ["Kyyn.Plugin"] >>= right
  forM_ ["name","configType","payloadType","fetch","validateConfig"] $ \field ->
    assert ("Missing reflected connector field documentation: " ++ field)
      (not (null [() | ApiModule _ symbols <- api, ApiSymbol name ValueNamespace origin _ _ (Just doc) <- symbols,
        name == field, "SourceConnector" `isInfixOf` origin, not (null doc)]))
  scope <- right (directoryScope temporary)
  toolchain <- GuestToolchain <$> right (directoryScope runtime)
  let load path = do
        directory <- right (directoryScope (repo </> path))
        runEff (runFailure (runFileSystemIO scope (readTree directory))) >>= right
  trees <- traverse load ["shared/kyyn-types/src","guest/kyyn-sdk/src","guest/kyyn-runtime/src"]
  json <- load "vendor/json/Text"
  jsonFiles <- traverse (\(p,b) -> (,) <$> right (relativePath ("Text/" ++ relativeName p)) <*> pure b) (files json)
  sdk <- right (fileTree (concatMap files trees ++ jsonFiles))
  package <- load "plugins/local-file"
  installed <- traverse (\(p,b) -> (,) <$> right (relativePath ("plugins/packages/local-file/source/" ++ relativeName p)) <*> pure b) (files package)
  sourceDirectory <- pure (temporary </> "documents")
  createDirectory sourceDirectory
  Bytes.writeFile (sourceDirectory </> "one.txt") "one"
  let configuration :: FilePath -> Bytes.ByteString
      configuration directory = Text.encodeUtf8 (Text.pack (unlines
        ["let Folder = < Folder : { directory : Text, recursive : Bool } >",
         "in [ { name = \"sales\", binding = \"salesFiles\", connector = Folder.Folder { directory = " ++ show directory ++ ", recursive = True } }",
         "   , { name = \"support\", binding = \"supportFiles\", connector = Folder.Folder { directory = " ++ show directory ++ ", recursive = False } } ]"]))
  configPath <- right (relativePath "plugins/config/local-file.dhall")
  code <- right (fileTree (installed ++ [(configPath,configuration sourceDirectory)]))
  prepared <- runPreparation scope toolchain sdk (preparePlugins code) >>= right
  report <- runPreparation scope toolchain sdk (validatePlugins prepared) >>= right
  assert "valid configuration was rejected" (report == ValidationReport [])
  case prepared of
    [PreparedPlugin (PreparedPackage plugin identity [PreparedConnector kind configContract payloadContract _ _ methods]) instances] -> do
      assert "plugin registration lost connector type or instances" (kind == ConnectorTypeName "Folder" && length instances == 2)
      authored <- traverse (\(p,b) -> (,) <$> right (relativePath p) <*> pure b)
        [(p,b) | (path,b) <- files package, Just p <- [stripPrefix "src/" (relativeName path)]]
      adapter <- right (acquisitionSources (rootType configContract) (rootType payloadContract)
        "LocalFile.Folder.fetch" (authored ++ files sdk))
      compileFirstParty (temporary </> "ghc-acquisition") adapter
      method@(PreparedMethod methodName description input output _) <- case methods of
        [m] -> pure m
        _ -> fail "Local-file should register exactly one content method"
      assert "Content method metadata lost" (methodName == MethodName "content" && "latest fetched text" `isInfixOf` description)
      readAdapter <- right (capturedReadSources (rootType input) (rootType payloadContract) (rootType output)
        "LocalFile.Read.content" (authored ++ files sdk))
      compileFirstParty (temporary </> "ghc-read") readAdapter
      mapM_ (\(ConfiguredConnector name _ (PreparedConnector _ _ payload entry _ _) config) -> do
        let invoke producerIdentity selected value = runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope (runDhallHandling
              (runDocumentPersistenceIO $ runEvidenceStore scope (runGuestExecution toolchain (runPluginRead
                (callCapturedMethod (ConnectorInstanceRef plugin (coerce name)) (EvidenceProducer producerIdentity (contractId payload)) payload selected value)))))))) >>= right
            arguments key = toJSON (key :: String)
            hasCode expectedCode result = case result of
              Left diagnostics -> any (\(Diagnostic _ actual _ _) -> expectedCode == actual) diagnostics
              Right _ -> False
        absent <- invoke identity method (arguments "one.txt")
        assert "Read before fetch was not refused" (hasCode "evidence.not-fetched" absent)
        snapshot <- runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope (runDhallHandling
          (runDocumentPersistenceIO $ runEvidenceStore scope (runFileAcquisitionIO (runGuestExecution toolchain (runEvidenceAcquisition
            (fetchEvidence (ConnectorInstanceRef plugin (coerce name)) identity payload entry config))))))))) >>= right >>= right
        current <- runEff (runFailure (runFileSystemIO scope (runDhallHandling (runDocumentPersistenceIO $ runEvidenceStore scope
          (loadCurrentEvidence (ConnectorInstanceRef plugin (coerce name)) (EvidenceProducer identity (contractId payload)) payload))))) >>= right >>= right
        assert "configured local-file did not fetch a real file" (case current of
          Just (CurrentEvidence selected items) -> selected == snapshot && length items == 1
          Nothing -> False)
        result <- invoke identity method (arguments "one.txt") >>= right
        assert "Content read returned the wrong payload" (result == CheckedValue (contractId output) (toJSON ("one" :: String)))
        missing <- invoke identity method (arguments "missing.txt")
        assert "Missing evidence was not a typed read failure" (hasCode "plugin.read-failed" missing)
        changed <- invoke (PackageIdentity "changed-producer") method (arguments "one.txt")
        assert "Changed producer did not preserve its refusal code" (hasCode "evidence.producer-changed" changed)
        malformed <- invoke identity method (toJSON True)
        assert "Invalid method input was accepted" (rejected malformed)) instances
    _ -> fail "Wrong plugin registration shape"
  initial <- right initialRootFiles
  invalidCode <- right (fileTree (files initial ++ installed ++ [(configPath,configuration "relative")]))
  rootResult <- runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope (runDhallHandling
    (runGuestExecution toolchain $ runGuestCompilation toolchain (runSchemaInspectionIO toolchain (runRootStore (noGit (runRootOpening sdk
      (runPluginPreparation sdk (runRootExecution sdk $ do
        opened <- openCapturedRoot invalidCode
        either (pure . Rejected . ValidationReport) checkRoot opened))))))))))) >>= right
  case rootResult of
    Rejected (ValidationReport diagnostics) -> assert "Root check lost per-instance config diagnostics"
      (length [() | Diagnostic Error _ _ _ <- diagnostics] == 2)
    Passed _ _ -> fail "Whole-root check accepted invalid plugin configuration"
  let wrongBinding (path,bytes)
        | relativeName path == "plugins/packages/local-file/source/src/LocalFile/Plugin.hs" =
            (path,Text.encodeUtf8 (Text.replace "LocalFile.Folder.fetch" "LocalFile.Config.validate" (Text.decodeUtf8 bytes)))
        | otherwise = (path,bytes)
  wrongCode <- right (fileTree (map wrongBinding installed))
  wrong <- runPreparation scope toolchain sdk (preparePlugins wrongCode)
  case wrong of
    Left diagnostics -> assert "Wrong fetch type diagnostic lost connector context"
      (any (\(Diagnostic _ _ message _) -> "local-file/Folder" `isInfixOf` message) diagnostics)
    Right _ -> fail "Registration accepted a config validator as its fetch function"
  putStrLn "Plugin registration: inspected real package, two independent configured fetches and pure per-instance validation passed."

compileFirstParty :: FilePath -> GuestSources -> IO ()
compileFirstParty directory sources = do
  ghc <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe
    (fail "The matching versioned GHC executable is required for the first-party plugin proof") pure
  forM_ (sourceFiles sources) $ \(path,bytes) -> do
    let target = directory </> relativeName path
    createDirectoryIfMissing True (takeDirectory target)
    Bytes.writeFile target bytes
  (status,out,err) <- readProcessWithExitCode ghc ["-v0","-fforce-recomp","-i" ++ directory,
    "-outputdir",directory </> "objects","-main-is","KyynPluginEntry.main",
    directory </> relativeName (selectedEntry sources),"-o",directory </> "native"] ""
  assert ("GHC rejected first-party local-file acquisition: " ++ out ++ err) (status == ExitSuccess)

runPreparation :: DirectoryScope -> GuestToolchain -> FileTree -> Eff Preparation a -> IO a
runPreparation scope toolchain sdk = (>>= right) . runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
  . runDhallHandling . runGuestExecution toolchain . runGuestCompilation toolchain . runSchemaInspectionIO toolchain . runPluginPreparation sdk
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

noGit :: Eff (Git : es) a -> Eff es a
noGit = interpret $ \_ _ -> error "Captured-root check attempted Git access"
