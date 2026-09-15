{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module ToolTests (testTools) where

import Control.Monad (unless, forM_)
import Data.Aeson (toJSON)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Version (showVersion)
import Effectful (Eff, runEff, (:>))
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (runState, modify)
import Kyyn.Domain.Contract (contractId)
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Path (DirectoryScope, scopePath, relativePath, relativeName)
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.MicroHs.Toolchain (GuestToolchain)
import Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation)
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.MicroHs.Interpreter.SchemaInspection (runSchemaInspectionIO)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation(..), compileGuest)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, sourceFiles, selectedEntry)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.KnowledgeBaseInitialization (initialRootFiles)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.Tool
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.ToolExecution (runToolExecution)
import System.Directory (createDirectoryIfMissing, findExecutable)
import System.FilePath ((</>), takeDirectory, takeBaseName)
import System.Exit (ExitCode(..))
import System.Info (compilerVersion)
import System.Process (readProcessWithExitCode)

testTools :: DirectoryScope -> GuestToolchain -> FileTree -> FileTree -> [PreparedPlugin] -> IO ()
testTools scope toolchain sdk pluginCode plugins = do
  initial <- right initialRootFiles
  helperPath <- right (relativePath "src/Helpers.hs")
  let helper = Text.encodeUtf8 (Text.unlines
        [ "module Helpers where"
        , "import Kyyn.Plugin (FetchError)"
        , "import Kyyn.Connectors (Tool)"
        , "import qualified Kyyn.Connectors as Connectors"
        , "import qualified Kyyn.Plugins.P_local_file.Folder as Files"
        , "type Input = [String]"
        , "type Output = [String]"
        , "bulk :: Input -> Tool (Either FetchError Output)"
        , "bulk ids = do"
        , "  a <- mapM (Files.content Connectors.salesFiles) ids"
        , "  b <- mapM (Files.content Connectors.supportFiles) ids"
        , "  missing <- Files.content Connectors.salesFiles \"absent.txt\""
        , "  pure $ case missing of"
        , "    Left _ -> sequence (a ++ b)"
        , "    Right value -> Right [value]"
        ])
      declaration = "[{ name = \"bulk\", description = \"Read both folders\", implementation = \"Helpers.bulk\", inputType = \"Helpers.Input\", resultType = \"Helpers.Output\" }]"
      empty = "[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }"
      manifest (path,bytes) | relativeName path == "kb.dhall" = (path,Text.encodeUtf8 (Text.replace empty declaration (Text.decodeUtf8 bytes)))
                            | otherwise = (path,bytes)
  code <- right (fileTree (map manifest (files initial) ++ files pluginCode ++ [(helperPath,helper)]))
  (prepared,sources) <- runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope (runDhallHandling
    (runGuestExecution toolchain (runGuestCompilation toolchain (runSchemaInspectionIO toolchain (runRootStore
      (captureCompilation (runToolPreparation sdk (prepareTools code plugins))))))))))) >>= right
  tools <- right prepared
  forM_ sources $ \source -> compileGhc scope source
  selected@(PreparedTool (ToolDescriptor _ _ _ result) _ _) <- case tools of
    [one] -> pure one
    _ -> fail "Expected the registered bulk tool"
  let invoke input = runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope (runDhallHandling
        (runGuestExecution toolchain (runDocumentPersistenceIO (runEvidenceStore scope (runPluginRead
          (runToolExecution (executeTool selected input)))))))))) >>= right
  value <- invoke (toJSON (["one.txt","one.txt"] :: [String])) >>= right
  assert "Tool did not compose instances or catch the typed missing-ID failure"
    (value == CheckedValue (contractId result) (toJSON (replicate 4 ("one" :: String))))
  invalid <- invoke (toJSON True)
  assert "Tool accepted an invalid argument" (case invalid of Left _ -> True; Right _ -> False)
  putStrLn "KB tools: generated proxies compiled in GHC/MicroHs; two-instance composition and catchable missing evidence passed."

captureCompilation :: GuestCompilation :> es => Eff (GuestCompilation : es) a -> Eff es (a,[GuestSources])
captureCompilation = reinterpret (runState []) $ \_ (CompileGuest sources) -> do
  modify (sources :)
  compileGuest sources

compileGhc :: DirectoryScope -> GuestSources -> IO ()
compileGhc scope sources = do
  let directory = scopePath scope </> "ghc-tool"
  ghc <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe (fail "Missing matching GHC") pure
  forM_ (sourceFiles sources) $ \(path,bytes) -> do
    let target = directory </> relativeName path
    createDirectoryIfMissing True (takeDirectory target)
    Bytes.writeFile target bytes
  (status,out,err) <- readProcessWithExitCode ghc ["-v0","-fno-code","-i" ++ directory,
    "-outputdir",directory </> "objects","-main-is",takeBaseName (relativeName (selectedEntry sources)) ++ ".main",
    directory </> relativeName (selectedEntry sources)] ""
  assert ("GHC rejected generated helper: " ++ out ++ err) (status == ExitSuccess)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
