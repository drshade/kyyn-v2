-- Captured-read/Agentic judgement flows under GHC/MicroHs with a recording host.
-- Checks answer assembly, failure, malformed replies and restricted request rows;
-- no live Jev call.

{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value(..), encode, object, (.=))
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Version (showVersion)
import Effectful (Eff, runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.DataType (DataType(StringType))
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.Judgement (Judgement(..), judge)
import Kyyn.Plumbing.Protocol.Judgement (encodeReply)
import Kyyn.Plumbing.Protocol.PluginMessages (PluginFrame(..), encodeResponse, success, failure, parseResult)
import Kyyn.Plumbing.Protocol.Tool
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Agentic.Questions
import qualified Agentic.Value as A
import Kyyn.Domain.Model (ModelFailure(..))
import System.Directory (createDirectoryIfMissing, findExecutable, listDirectory, doesDirectoryExist)
import System.Environment (getEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.Info (compilerVersion)
import System.IO (hFlush, hClose, hIsEOF, hGetContents, hSetBinaryMode)
import qualified Kyyn.Plumbing.Protocol.Frame as Wire
import System.IO.Temp (withSystemTempDirectory)
import System.Process
import System.Timeout (timeout)

main :: IO ()
main = withSystemTempDirectory "kyyn-judgement-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  ghc <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe (fail "Missing matching GHC") pure
  let path = either error id . relativePath
      load base file = (,) (path file) <$> Bytes.readFile (repo </> base </> file)
  trees <- mapM (\dir -> collect (repo </> dir) "") ["shared/kyyn-types/src","guest/kyyn-sdk/src","guest/kyyn-runtime/src","vendor/agentic/src","vendor/transformers"]
  common <- sequence ([load dir file | (dir,paths) <- zip ["shared/kyyn-types/src","guest/kyyn-sdk/src","guest/kyyn-runtime/src","vendor/agentic/src","vendor/transformers"] trees, file <- paths] ++
    [load "vendor/json" file | file <- ["Text/JSON/Types.hs","Text/JSON/String.hs"]] ++
    [load "host/kyyn-microhs/test/judgement" "Helpers.hs"])
  let plugin = either error id (pluginName "fixture")
      kind = either error id (connectorTypeName "Folder")
      method = either error id (methodName "content")
      binding = either error id (bindingName "documents")
      instanceName = either error id (connectorName "documents")
  sources <- right (toolSources [ConnectorInterface plugin kind StringType [(method,StringType,StringType)]]
    [InstanceBinding binding plugin kind instanceName] StringType StringType "Helpers.run" common)
  forM_ (sourceFiles sources) $ \(file,bytes) -> do
    let target = temporary </> relativeName file
    createDirectoryIfMissing True (takeDirectory target)
    Bytes.writeFile target (if take 7 (relativeName file) == "Agentic"
      then "{-# LANGUAGE NoFieldSelectors, OverloadedRecordDot, DuplicateRecordFields #-}\n" <> bytes else bytes)
  let executable = temporary </> "native"
  let extensions = ["-XGHC2021","-XDataKinds","-XDefaultSignatures","-XDeriveAnyClass",
        "-XDerivingVia","-XGADTs","-XLambdaCase","-XOverloadedStrings","-XRankNTypes"]
  (status,out,err) <- readProcessWithExitCode ghc (extensions ++ ["-v0","-i","-i" ++ temporary,
    "-outputdir",temporary </> "objects","-main-is","KyynToolEntry.main",
    temporary </> relativeName (selectedEntry sources),"-o",executable]) ""
  assert ("GHC rejected judgement: " ++ out ++ err) (status == ExitSuccess)
  scope <- right (directoryScope temporary)
  compiler <- GuestToolchain <$> right (directoryScope toolchain)
  artifact <- runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope
    (runGuestCompilation compiler Nothing (compileGuest sources))))) >>= right >>= right
  let CompiledProgram _ (_,bytes) = artifact
      bytecode = temporary </> "program.comb"
  Bytes.writeFile bytecode bytes
  forM_ [proc executable [],proc (toolchain </> "bin/mhseval") ["+RTS","-r" ++ bytecode,"-RTS"]] $ \program -> do
    (result,trace,code) <- broker Normal program
    let expected = "(Urgent,9500,8000,1.25,[Routine,Important,Urgent],[Routine,Important,Urgent])"
    assert "typed results or continuation differed" (result == Just (success (String (Text.pack expected))) && code == ExitSuccess)
    assert "wrong composition trace" (trace == ["read","judge"])
    (refused,refusalTrace,refusalCode) <- broker Refused program
    assert "typed refusal not handled" (refused == Just (failure "The model provider is rate limiting requests; retry later.") && refusalTrace == ["read","judge"] && refusalCode == ExitSuccess)
    (malformed,_,malformedCode) <- broker OutOfRange program
    assert "out-of-range wire probability accepted" (malformed == Nothing && malformedCode /= ExitSuccess)
    forM_ [MissingAnswer,ExtraAnswer,WrongAnswer] $ \scenario -> do
      (bad,_,badCode) <- broker scenario program
      assert "malformed batch assembled" (case fmap parseResult bad of
        Just (Right (Left _)) -> badCode == ExitSuccess
        _ -> False)
  forM_ [
    ("query", "invalid :: Query.Query () Bool\ninvalid = interpret assessment \"x\"\n"),
    ("pure validator", "invalid :: () -> Bool\ninvalid _ = interpret assessment \"x\"\n"),
    ("dependent question", "invalid :: Questions YesNo\ninvalid = yesNo \"q\" >>= pure\n")
    ] $ \(label,extra) -> do
      let files = [(file, if relativeName file == "Helpers.hs" then content <> Text.encodeUtf8 (Text.pack ("\n" ++ extra)) else content)
            | (file,content) <- sourceFiles sources]
      invalid <- right (guestSources (selectedEntry sources) files)
      forM_ files $ \(file,content) -> Bytes.writeFile (temporary </> relativeName file) content
      (invalidStatus,_,_) <- readProcessWithExitCode ghc (extensions ++ ["-v0","-fno-code","-fforce-recomp","-i","-i" ++ temporary,
        temporary </> relativeName (selectedEntry invalid)]) ""
      assert ("GHC accepted " ++ label) (invalidStatus /= ExitSuccess)
      refused <- runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope
        (runGuestCompilation compiler Nothing (compileGuest invalid))))) >>= right
      assert ("MicroHs accepted " ++ label) (case refused of Left _ -> True; Right _ -> False)
  putStrLn "Judgement generated tool passed GHC and MicroHs: captured read, applicative batch, refusals, Agentic codec and query/validation/Monad exclusions."

data Scenario = Normal | Refused | OutOfRange | MissingAnswer | ExtraAnswer | WrongAnswer deriving Eq

recording :: Scenario -> Eff (Judgement : es) a -> Eff es a
recording scenario = interpret $ \_ (Judge (JudgeRequest _ questions)) -> pure $
  if scenario == Refused then Left ModelRateLimited else Right (alter (map answer questions))
  where
    alter :: [Answer] -> [Answer]
    alter values = case scenario of
      MissingAnswer -> drop 1 values
      ExtraAnswer -> values ++ values
      WrongAnswer -> reverse values
      _ -> values
    answer (AskYesNo _) = YesNoAnswer 0.95
    answer (AskChoice _ options) = ChoiceAnswer "Urgent" (zip (map fst options) [0.05,0.05,0.9]) 0.8
    answer (AskScore _ levels) = ScoreAnswer 1.25 (zip [0 .. length levels - 1] [0,0.75,0.25]) 0.7

broker :: Scenario -> CreateProcess -> IO (Maybe Value,[String],ExitCode)
broker scenario program = do
  result <- timeout 20000000 $ withCreateProcess program { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe } $ \input output errors process ->
    case (input,output,errors) of
      (Just toGuest,Just fromGuest,Just diagnostics) -> do
        hSetBinaryMode toGuest True
        hSetBinaryMode fromGuest True
        let emit bytes = mapM_ (Bytes.hPut toGuest) (Wire.encodeFrame (Wire.jsonFrame bytes)) >> hFlush toGuest
            next = do
              bytes <- Bytes.hGetSome fromGuest 32768
              pure (if Bytes.null bytes then Nothing else Just bytes)
            loop buffered trace = do
              eof <- hIsEOF fromGuest
              if eof && Bytes.null buffered then pure (Nothing,trace) else do
                (Wire.Frame line body,rest) <- Wire.readFrame next buffered >>= right
                assert "non-HTTP frame has raw body" (Bytes.null body)
                frame <- right (decodeToolFrame line)
                case frame of
                  Completed value -> pure (Just value,trace)
                  HostRequest identity call -> do
                    assert "request order" (identity == toInteger (length trace + 1))
                    (label,reply) <- case call of
                      ToolModel _ -> fail "Judgement fixture unexpectedly requested a model"
                      ToolEvidenceList {} -> fail "Judgement fixture unexpectedly enumerated evidence"
                      ToolEvidenceRead {} -> fail "Judgement fixture unexpectedly read evidence"
                      ToolCall _ _ _ _ value -> do
                        assert "captured-read argument" (value == String "item")
                        pure ("read",success (String "captured 雪"))
                      ToolJudgement request@(JudgeRequest context questions) -> do
                        assert "captured context lost" (context == A.String "captured 雪")
                        assert "questions not batched" (length questions == 3)
                        let reply = runPureEff (recording scenario (judge request))
                        encoded <- right (encodeReply reply)
                        pure ("judge",if scenario == OutOfRange
                          then object ["tag" .= ("Right" :: String), "value" .= [object ["tag" .= ("YesNo" :: String), "value" .= ("10001" :: String)]]]
                          else encoded)
                    emit (encodeResponse identity reply)
                    loop rest (trace ++ [label])
        emit (Lazy.toStrict (encode (String "item")))
        (value,trace) <- loop Bytes.empty []
        hClose toGuest
        diagnostic <- hGetContents diagnostics
        length diagnostic `seq` pure ()
        code <- waitForProcess process
        pure (value,trace,code)
      _ -> fail "Missing protocol pipes"
  maybe (fail "Judgement protocol timed out") pure result

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

collect :: FilePath -> FilePath -> IO [FilePath]
collect base relative = do
  entries <- listDirectory (base </> relative)
  fmap concat $ mapM (\name -> do
    let path = relative </> name
    directory <- doesDirectoryExist (base </> path)
    if directory then collect base path else pure [path | reverse (take 3 (reverse path)) == ".hs"]) entries
