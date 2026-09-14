{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, IOE, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (ValidationReport(..), Diagnostic(..), Severity(..), CheckResult(..))
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Path (DirectoryScope, directoryScope, relativePath, relativeName)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..))
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
import Kyyn.Plumbing.Capability.Git (Git)
import Kyyn.Plumbing.Capability.EvidenceStore (listEvidenceIds)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.EvidenceStore (runEvidenceStoreIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileAcquisition (runFileAcquisitionIO)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Capability.EvidenceAcquisition (fetchEvidence)
import Kyyn.Porcelain.Interpreter.EvidenceAcquisition (runEvidenceAcquisition)
import Kyyn.Porcelain.Capability.KnowledgeBaseInitialization (initialRootFiles)
import Kyyn.Porcelain.Capability.RootOpening (openCapturedRoot)
import Kyyn.Porcelain.Capability.Validation (checkRoot)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import System.Directory (createDirectory)
import System.Environment (getEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

type Preparation = '[PluginPreparation, SchemaInspection, GuestCompilation, DhallHandling, FileSystem, ProcessExecution, Failure, IOE]

main :: IO ()
main = withSystemTempDirectory "kyyn-registration-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  runtime <- getEnv "KYYN_TEST_TOOLCHAIN"
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
    [PreparedPlugin plugin identity [PreparedConnector kind _ _ _ _] instances] -> do
      assert "plugin registration lost connector type or instances" (kind == "Folder" && length instances == 2)
      mapM_ (\(ConfiguredConnector name _ (PreparedConnector _ _ payload entry _) config) -> do
        snapshot <- runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope (runDhallHandling
          (runEvidenceStoreIO scope (runFileAcquisitionIO (runGuestExecution toolchain (runEvidenceAcquisition
            (fetchEvidence (ConnectorInstanceRef plugin name) identity payload entry config))))))))) >>= right >>= right
        ids <- runEff (runFailure (runFileSystemIO scope (runDhallHandling (runEvidenceStoreIO scope
          (listEvidenceIds snapshot payload))))) >>= right >>= right
        assert "configured local-file did not fetch a real file" (length ids == 1)) instances
    _ -> fail "Wrong plugin registration shape"
  initial <- right initialRootFiles
  invalidCode <- right (fileTree (files initial ++ installed ++ [(configPath,configuration "relative")]))
  rejected <- runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope (runDhallHandling
    (runGuestCompilation toolchain (runSchemaInspectionIO toolchain (runRootStore (noGit (runRootOpening sdk
      (runPluginPreparation sdk (runRootExecution sdk $ do
        opened <- openCapturedRoot invalidCode
        either (pure . Rejected . ValidationReport) checkRoot opened))))))))))) >>= right
  case rejected of
    Rejected (ValidationReport diagnostics) -> assert "Root check lost per-instance config diagnostics"
      (length [() | Diagnostic Error _ _ _ <- diagnostics] == 2)
    Passed _ _ -> fail "Whole-root check accepted invalid plugin configuration"
  putStrLn "Plugin registration: inspected real package, two independent configured fetches and pure per-instance validation passed."

runPreparation :: DirectoryScope -> GuestToolchain -> FileTree -> Eff Preparation a -> IO a
runPreparation scope toolchain sdk = (>>= right) . runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
  . runDhallHandling . runGuestCompilation toolchain . runSchemaInspectionIO toolchain . runPluginPreparation sdk
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

noGit :: Eff (Git : es) a -> Eff es a
noGit = interpret $ \_ _ -> error "Captured-root check attempted Git access"
