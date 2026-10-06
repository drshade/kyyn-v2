-- Captured model config, generated instances and tool dispatch through real MicroHs
-- pipes with a recording provider: nested records, retry and refusal. No live model.

{-# LANGUAGE DataKinds, GADTs, OverloadedStrings, OverloadedRecordDot, TypeApplications #-}
module Main (main) where

import qualified Agentic as A
import qualified Agentic.Runtime as A
import Control.Monad (unless, forM_)
import Data.Aeson (toJSON, object, (.=))
import qualified Data.ByteString as Bytes
import Data.List (isInfixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, runEff, runPureEff, (:>))
import Effectful.Dispatch.Dynamic (interpret, reinterpret)
import Effectful.State.Static.Local (runState, get, put)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Model (ModelConfiguration(..), ModelProvider(..), ModelFailure(..))
import Kyyn.Domain.Path (directoryScope, relativePath, relativeName)
import Kyyn.Domain.Secret (secretName)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation)
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.MicroHs.Interpreter.SchemaInspection (runSchemaInspectionIO)
import Kyyn.Plumbing.Capability.FileSystem (readTree)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation(..), compileGuest)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, sourceFiles, selectedEntry)
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn(..))
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.KnowledgeBaseInitialization (initialRootFiles)
import Kyyn.Porcelain.Capability.PluginRead (PluginRead)
import Kyyn.Porcelain.Capability.RootStore (readRootDefinition)
import Kyyn.Porcelain.Capability.Tool
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.ToolExecution (runToolExecution)
import System.Environment (getEnv, setEnv)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)

main :: IO ()
main = withSystemTempDirectory "kyyn-model-tool-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  runtime <- getEnv "KYYN_TEST_TOOLCHAIN"
  setEnv "MHSCPPHS" (runtime </> "bin/cpphs")
  scope <- right (directoryScope temporary)
  toolchain <- GuestToolchain <$> right (directoryScope runtime)
  let load path = do
        directory <- right (directoryScope (repo </> path))
        runEff (runFailure (runFileSystemIO scope (readTree directory))) >>= right
  trees <- traverse load ["shared/kyyn-types/src","guest/kyyn-sdk/src","guest/kyyn-runtime/src","vendor/agentic/src","vendor/transformers"]
  json <- load "vendor/json/Text"
  jsonFiles <- traverse (\(p,b) -> (,) <$> right (relativePath ("Text/" ++ relativeName p)) <*> pure b) (files json)
  sdk <- right (fileTree (concatMap files trees ++ jsonFiles))
  initial <- right initialRootFiles
  helperPath <- right (relativePath "src/Helpers.hs")
  typesPath <- right (relativePath "src/ModelTypes.hs")
  instancesPath <- right (relativePath "src/ModelInstances.hs")
  modelPath <- right (relativePath "model.dhall")
  let helper = Text.encodeUtf8 (Text.unlines
        ["{-# LANGUAGE OverloadedStrings #-}", "module Helpers where",
         "import ModelTypes (Answer)",
         "import ModelInstances ()",
         "import qualified Agentic as A", "import qualified Data.Text as Text",
         "import Kyyn.Agentic (Flow, interpret)", "import Kyyn.Connectors (Tool)", "import Kyyn.Plugin (FetchError)",
         "type Input = String", "type Output = Answer",
         "inner :: Flow Text.Text Answer", "inner = A.draft \"inner\"",
         "outer :: Flow Text.Text Answer", "outer = A.draftWith [A.tool \"helper\" \"nested draft\" inner] \"outer\"",
         "helper :: Input -> Tool (Either FetchError Output)",
         "helper input = interpret outer (Text.pack input)"])
      declaration = "[{ name = \"draft\", description = \"Model fixture\", implementation = \"Helpers.helper\", inputType = \"Helpers.Input\", resultType = \"Helpers.Output\" }]"
      empty = "[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }"
      manifest (p,b) | relativeName p == "kb.dhall" = (p,Text.encodeUtf8 (Text.replace empty declaration (Text.decodeUtf8 b)))
                     | otherwise = (p,b)
      types = "module ModelTypes where\ndata Answer = Answer { message :: String }\ntype Alias = Answer\n"
      instances = "{-# LANGUAGE CPP #-}\nmodule ModelInstances where\n#if 0\nimport Kyyn.Contracts.NotPresent.Bad ()\n#endif\nimport {- generated -} Kyyn.Contracts.ModelTypes.Answer\n  ()\nimport qualified Kyyn.Contracts.ModelTypes.Answer as Answer ()\n"
      base = map manifest (files initial) ++ [(helperPath,helper),(typesPath,types),(instancesPath,instances)]
      config = "{ provider = < OpenAI | Anthropic >.Anthropic, model = \"fixture-model\", credential = \"MODEL_KEY\" }"
      prepare tree = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
        . runGuestExecution toolchain . runGuestCompilation toolchain Nothing . runSchemaInspectionIO toolchain Nothing . runRootStore
        . captureCompilation . runToolPreparation sdk $ prepareTools tree []
  configured <- right (fileTree (base ++ [(modelPath,config)]))
  (prepared,sources) <- prepare configured >>= right
  selected <- right prepared >>= only
  forM_ ["Missing","Alias"] $ \selectedType -> do
    let badInstance = Text.encodeUtf8 (Text.pack ("module ModelInstances where\nimport Kyyn.Contracts.ModelTypes." ++ selectedType ++ " ()\n"))
    bad <- right (fileTree [(path,if path == instancesPath then badInstance else bytes) | (path,bytes) <- files configured])
    (refused,compiled) <- prepare bad >>= right
    assert "Bad contract request compiled a guest" (null compiled)
    assert "Missing/aliased contract lacked a diagnostic" (hasDiagnostic selectedType refused)
  cyclic <- right (fileTree [(path,if path == typesPath then
    "module ModelTypes where\nimport Kyyn.Contracts.ModelTypes.Answer ()\ndata Answer = Answer { message :: String }\n"
    else bytes) | (path,bytes) <- files configured])
  (cycleResult,_) <- prepare cyclic >>= right
  assert "Circular generated contract lacked authoring guidance" (hasDiagnostic "separate module" cycleResult)
  forM_ sources $ \source -> do
    let directory = temporary </> "ghc"
    forM_ (sourceFiles source) $ \(path,bytes) -> do
      let target = directory </> relativeName path
      createDirectoryIfMissing True (takeDirectory target)
      Bytes.writeFile target (if take 7 (relativeName path) == "Agentic"
        then "{-# LANGUAGE NoFieldSelectors, OverloadedRecordDot, DuplicateRecordFields #-}\n" <> bytes else bytes)
    (status,output,errors) <- readProcessWithExitCode "ghc-9.10.3"
      ["-v0","-fno-code","-XGHC2021","-XDataKinds","-XDefaultSignatures","-XDeriveAnyClass",
       "-XDerivingVia","-XGADTs","-XLambdaCase","-XOverloadedStrings","-XRankNTypes",
       "-i" ++ directory,"-outputdir",directory </> "objects",directory </> relativeName (selectedEntry source)] ""
    assert ("GHC rejected generated model tool: " ++ output ++ errors) (status == ExitSuccess)
  key <- right (secretName "MODEL_KEY")
  let expected = ModelConfiguration Anthropic "fixture-model" key
  case selected of
    PreparedTool _ _ _ captured -> assert "Model selection wasn't captured" (captured == Just expected)
  forM_ ["{ provider = < OpenAI | Anthropic >.OpenAI, model = \" \" , credential = \"KEY\" }",
    "{ provider = < OpenAI | Anthropic >.OpenAI, model = \"model\", credential = \"bad/key\" }",
    "{ model = \"missing fields\" }", "\255"] $ \bad -> do
      tree <- right (fileTree (base ++ [(modelPath,bad)]))
      assert "Root accepted malformed model configuration"
        (case runPureEff (runDhallHandling (runRootStore (readRootDefinition tree))) of Left _ -> True; Right _ -> False)
  let invoke tool handler = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
        . runGuestExecution toolchain . noReads . noJudgement . handler . runToolExecution $
          executeTool tool (toJSON ("input" :: String))
  (result,turns) <- invoke selected (recording expected) >>= right
  CheckedValue _ value <- right result
  assert "Wrong final model value" (value == object ["message" .= ("final 雪" :: String)])
  assert "Nested draft/retry didn't stay in the guest" (turns == 4)
  missing <- invoke (withoutModel selected) (recording expected) >>= right
  assert "Unconfigured model contacted provider" (snd missing == 0)
  assert "Missing model not actionable" (hasDiagnostic "root/model.dhall" (fst missing))
  (failed,_) <- invoke selected refusing >>= right
  assert "Provider refusal didn't return an actionable tool diagnostic" (hasDiagnostic "model refused" failed)
  putStrLn "Model tools: captured config, root validation, real guest nested calls/retry and typed refusal passed."

recording :: ModelConfiguration -> Eff (ModelTurn : es) a -> Eff es (a,Int)
recording expected = reinterpret (runState (0 :: Int)) $ \_ (TakeModelTurn configuration conversation) -> do
  n <- get @Int
  put (n + 1)
  unless (configuration == expected) (error "Changed captured model selection")
  let raw = A.Raw (A.Object [("n",A.Integer (900719925474099312345 + toInteger n)),("float",A.Number 0.25)])
      turn = A.Turn raw
  pure $ case (n,conversation.instruction.text,conversation.history) of
    (0,"outer",[]) -> Right (turn (A.CallTools [A.ToolCall "nested" "helper" (A.String "nested input")]))
    (1,"inner",[]) -> Right (turn (A.Respond A.Null))
    (2,"inner",[A.Rejected (A.Raw (A.Object _)) _]) -> Right (turn (A.Respond (A.Object [("message",A.String "nested answer")])))
    (3,"outer",[A.Called (A.Raw (A.Object _)) [("nested",A.ToolOk (A.Object [("message",A.String "nested answer")]))]]) ->
      Right (turn (A.Respond (A.Object [("message",A.String "final 雪")])))
    _ -> error ("Unexpected guest model request: " ++ show conversation)

captureCompilation :: GuestCompilation :> es => Eff (GuestCompilation : es) a -> Eff es (a,[GuestSources])
captureCompilation = reinterpret (runState []) $ \_ (CompileGuest sources) -> do
  previous <- get @[GuestSources]
  put (sources : previous)
  compileGuest sources

refusing :: Eff (ModelTurn : es) a -> Eff es (a,Int)
refusing = reinterpret (runState (0 :: Int)) $ \_ (TakeModelTurn _ _) -> pure (Left ModelRefused)

noReads :: Eff (PluginRead : es) a -> Eff es a
noReads = interpret $ \_ _ -> error "Model fixture unexpectedly read evidence"
noJudgement :: Eff (Judgement : es) a -> Eff es a
noJudgement = interpret $ \_ _ -> error "Model fixture unexpectedly requested Judgement"

withoutModel :: PreparedTool -> PreparedTool
withoutModel (PreparedTool a b c _) = PreparedTool a b c Nothing
hasDiagnostic :: String -> Either [Diagnostic] a -> Bool
hasDiagnostic text (Left diagnostics) = any (\(Diagnostic _ _ message _) -> text `isInfixOf` message) diagnostics
hasDiagnostic _ _ = False
only :: [a] -> IO a
only [x] = pure x
only _ = fail "Expected one prepared tool"
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
