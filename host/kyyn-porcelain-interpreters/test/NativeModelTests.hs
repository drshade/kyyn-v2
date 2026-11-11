-- Native guest model turns through the production tool broker: nested calls,
-- malformed-response retries, captured configuration, judgement batching and
-- refusals. No live provider is contacted.
{-# LANGUAGE DataKinds, GADTs, OverloadedStrings, OverloadedRecordDot, TypeApplications #-}
module Main (main) where
import qualified Agentic as A
import qualified Agentic.Runtime as A
import qualified Agentic.Questions as Q
import Control.Monad (unless, forM_)
import Data.Aeson (toJSON, object, (.=))
import qualified Data.ByteString as Bytes
import Data.List (isInfixOf)
import qualified Data.Text as Text
import Effectful (Eff, runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret, reinterpret)
import Effectful.State.Static.Local (runState, get, put)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Model (ModelConfiguration(..), ModelProvider(..), ModelFailure(..))
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin (MethodName(..))
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Domain.Secret (secretName)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn(..))
import Kyyn.Plumbing.Capability.Judgement (Judgement(..))
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.PluginRead (PluginRead(..))
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Porcelain.Capability.RootStore (readRootDefinition)
import Kyyn.Porcelain.Capability.Tool
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Protocol.ToolBroker (executeToolProgram)
import System.Environment (getArgs)
import System.Directory (canonicalizePath)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = do
  arguments <- getArgs
  executable <- case arguments of [selected] -> canonicalizePath selected; _ -> fail "Expected native model guest"
  let path = either error id . relativePath
  fixture <- mapM (\name -> (,) (path name) <$> Bytes.readFile ("tools/fixtures/model-guest/" ++ name)) ["kb.dhall"]
  code <- right (fileTree (fixture ++ [(path "flake.nix","{}"),(path "flake.lock","{}")] ))
  source <- right (guestSources RootEntries (files code))
  let program = CompiledProgram (BuildIdentity (sourceIdentity source) "fixture-system" "fixture.drv" (takeDirectory (takeDirectory executable))) executable ".build/model-guest"
      compilation = interpret (\_ (CompileGuest selected) -> if selected == source then pure (Right program) else error "Unexpected compilation")
  withSystemTempDirectory "kyyn-model-guest" $ \directory -> do
    scope <- right (directoryScope directory)
    prepared <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . compilation
      . runPluginPreparation . runToolPreparation $ prepareTools code
    selectedTools <- right prepared >>= right
    PreparedTool _ entry plugins model <- only [tool | tool@(PreparedTool (ToolDescriptor name _ _ _) _ _ _) <- selectedTools, name == MethodName "draft"]
    PreparedTool _ judgementEntry _ _ <- only [tool | tool@(PreparedTool (ToolDescriptor name _ _ _) _ _ _) <- selectedTools, name == MethodName "assess"]
    key <- right (secretName "MODEL_KEY")
    let expected = ModelConfiguration Anthropic "fixture-model" key
    assert "Model selection was not captured" (model == Just expected && null plugins)
    forM_ ["Some { provider = < OpenAI | Anthropic >.OpenAI, model = \" \", credential = \"KEY\" }",
      "Some { provider = < OpenAI | Anthropic >.OpenAI, model = \"model\", credential = \"bad/key\" }",
      "Some { model = \"missing fields\" }", "\255"] $ \bad -> do
      tree <- right (fileTree [(name,if relativeName name == "kb.dhall" then "(" <> bytes <> ") // { model = " <> bad <> " }" else bytes) | (name,bytes) <- files code])
      assert "Root accepted malformed model configuration"
        (case runPureEff (runDhallHandling (runRootStore (readRootDefinition tree))) of Left _ -> True; Right _ -> False)
    withoutModel <- right (fileTree [(name,if relativeName name == "kb.dhall"
      then "(" <> bytes <> ") // { model = None { provider : < OpenAI | Anthropic >, model : Text, credential : Text } }" else bytes) | (name,bytes) <- files code])
    assert "Root refused an explicit absent model"
      (case runPureEff (runDhallHandling (runRootStore (readRootDefinition withoutModel))) of Right _ -> True; Left _ -> False)
    forM_ ["schemaType,schemaMetadata,validator,queries,tools,views,outputs",
      "schemaType,schemaMetadata,validator,queries,tools,views,model"] $ \projection -> do
      missingField <- right (fileTree [(name,if relativeName name == "kb.dhall"
        then "(" <> bytes <> ").{" <> projection <> "}" else bytes) | (name,bytes) <- files code])
      assert "Root accepted missing model or outputs"
        (case runPureEff (runDhallHandling (runRootStore (readRootDefinition missingField))) of Left _ -> True; Right _ -> False)
    let invoke selected handler = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
          . runGuestExecution [("LC_ALL","C.UTF-8")] . noEvidence . noReads . noJudgement . handler $
            executeToolProgram entry plugins selected [] (toJSON ("input" :: String))
    (result,turns) <- invoke model (recording expected) >>= right
    value <- right result
    assert "Wrong final model value" (value == object ["message" .= ("final 雪" :: String)])
    assert "Nested draft/retry did not stay in guest" (turns == 4)
    missing <- invoke Nothing (recording expected) >>= right
    assert "Unconfigured model contacted provider" (snd missing == 0)
    assert "Missing model not actionable" (hasDiagnostic "root/kb.dhall" (fst missing))
    (failed,_) <- invoke model refusing >>= right
    assert "Provider refusal not actionable" (hasDiagnostic "model refused" failed)
    forM_ [Normal, Refused, MissingAnswer, ExtraAnswer, WrongAnswer] $ \scenario -> do
      (judged,count) <- right =<< (runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
        . runGuestExecution [("LC_ALL","C.UTF-8")] . noEvidence . noReads . noModel . recordingJudgement scenario $
          executeToolProgram judgementEntry [] Nothing [] (toJSON ("captured 雪" :: String)))
      assert "Judgement batch was split or lost" (count == 1)
      case scenario of
        Normal -> assert "Typed judgement answers changed" (judged == Right (toJSON ("(Urgent,9500,8000,1.25,[Routine,Important,Urgent],[Routine,Important,Urgent])" :: String)))
        Refused -> assert "Judgement refusal was lost" (hasDiagnostic "rate limiting" judged)
        _ -> assert "Malformed judgement batch assembled" (case judged of Left _ -> True; _ -> False)
  putStrLn "Native model calls, retry, captured configuration, judgement batches passed."

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

refusing :: Eff (ModelTurn : es) a -> Eff es (a,Int)
refusing = reinterpret (runState (0 :: Int)) $ \_ (TakeModelTurn _ _) -> pure (Left ModelRefused)

noReads :: Eff (PluginRead : es) a -> Eff es a
noReads = interpret $ \_ operation -> case operation of
  ResolveCapturedBlobs [] _ _ -> pure (Right [])
  _ -> error "Model fixture unexpectedly read evidence"
noJudgement :: Eff (Judgement : es) a -> Eff es a
noJudgement = interpret $ \_ _ -> error "Model fixture unexpectedly requested Judgement"

noEvidence :: Eff (EvidenceStore : es) a -> Eff es a
noEvidence = interpret $ \_ _ -> error "Model fixture unexpectedly accessed evidence storage"

hasDiagnostic :: String -> Either [Diagnostic] a -> Bool
hasDiagnostic text (Left diagnostics) = any (\(Diagnostic _ _ message _) -> text `isInfixOf` Text.unpack message) diagnostics
hasDiagnostic _ _ = False
only :: [a] -> IO a
only [x] = pure x
only _ = fail "Expected one prepared tool"
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

data Scenario = Normal | Refused | MissingAnswer | ExtraAnswer | WrongAnswer deriving Eq
recordingJudgement :: Scenario -> Eff (Judgement : es) a -> Eff es (a,Int)
recordingJudgement scenario = reinterpret (runState (0 :: Int)) $ \_ (Judge (Q.JudgeRequest context questions)) -> do
  count <- get @Int
  put (count + 1)
  unless (context == A.String "captured 雪" && length questions == 3) (error "Judgement context or applicative batch changed")
  pure $ if scenario == Refused then Left ModelRateLimited else Right (alter (map answer questions))
  where
    alter :: [Q.Answer] -> [Q.Answer]
    alter values = case scenario of MissingAnswer -> drop 1 values; ExtraAnswer -> values ++ values; WrongAnswer -> reverse values; _ -> values
    answer (Q.AskYesNo _) = Q.YesNoAnswer 0.95
    answer (Q.AskChoice _ options) = Q.ChoiceAnswer "Urgent" (zip (map fst options) [0.05,0.05,0.9]) 0.8
    answer (Q.AskScore _ levels) = Q.ScoreAnswer 1.25 (zip [0 .. length levels - 1] [0,0.75,0.25]) 0.7
noModel :: Eff (ModelTurn : es) a -> Eff es a
noModel = interpret $ \_ _ -> error "Judgement fixture requested a model turn"
