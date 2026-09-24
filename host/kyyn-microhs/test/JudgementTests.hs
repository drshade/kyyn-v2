{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value(..), encode)
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
import Kyyn.Plumbing.Protocol.PluginMessages (PluginFrame(..), encodeResponse, success)
import Kyyn.Plumbing.Protocol.Tool
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Types.Judgement
import System.Directory (createDirectoryIfMissing, findExecutable)
import System.Environment (getEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.Info (compilerVersion)
import System.IO (hGetLine, hPutStrLn, hFlush, hClose, hIsEOF, hGetContents)
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
  common <- sequence
    ([load "shared/kyyn-types/src" ("Kyyn/Types/" ++ name ++ ".hs") | name <- ["Judgement","Program","Evidence","Plugin"]] ++
     [load "guest/kyyn-sdk/src" file | file <- ["Kyyn/Plugin.hs","Kyyn/Judgement/Internal.hs","Kyyn/Judgement/Question.hs"]] ++
     [load "guest/kyyn-runtime/src" ("Kyyn/Runtime/" ++ name ++ ".hs") | name <- ["Json","Plugin","Judgement"]] ++
     [load "vendor/json" file | file <- ["Text/JSON/Types.hs","Text/JSON/String.hs"]] ++
     [load "host/kyyn-microhs/test/judgement" "Helpers.hs"])
  let plugin = either error id (pluginName "fixture")
      kind = either error id (connectorTypeName "Folder")
      method = either error id (methodName "content")
      binding = either error id (bindingName "documents")
      instanceName = either error id (connectorName "documents")
  sources <- right (toolSources [ConnectorInterface plugin kind [(method,StringType,StringType)]]
    [InstanceBinding binding plugin kind instanceName] StringType StringType "Helpers.run" common)
  forM_ (sourceFiles sources) $ \(file,bytes) -> do
    let target = temporary </> relativeName file
    createDirectoryIfMissing True (takeDirectory target)
    Bytes.writeFile target bytes
  let executable = temporary </> "native"
  (status,out,err) <- readProcessWithExitCode ghc ["-v0","-i","-i" ++ temporary,
    "-outputdir",temporary </> "objects","-main-is","KyynToolEntry.main",
    temporary </> relativeName (selectedEntry sources),"-o",executable] ""
  assert ("GHC rejected judgement: " ++ out ++ err) (status == ExitSuccess)
  scope <- right (directoryScope temporary)
  compiler <- GuestToolchain <$> right (directoryScope toolchain)
  artifact <- runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope
    (runGuestCompilation compiler (compileGuest sources))))) >>= right >>= right
  let CompiledProgram _ (_,bytes) = artifact
      bytecode = temporary </> "program.comb"
  Bytes.writeFile bytecode bytes
  forM_ [proc executable [],proc (toolchain </> "bin/mhseval") ["+RTS","-r" ++ bytecode,"-RTS"]] $ \program -> do
    (result,trace,code) <- broker Normal program
    let expected = "captured 雪|" ++ "(Urgent,9500,8000,12500,[Routine,Important,Urgent],[Routine,Important,Urgent])"
    assert "typed results or continuation differed" (result == Just (success (String (Text.pack expected))) && code == ExitSuccess)
    assert "wrong composition trace" (trace == ["read","judge"])
    (refused,refusalTrace,refusalCode) <- broker Refused program
    assert "typed refusal not handled" (refused == Just (success (String "RateLimited")) && refusalTrace == ["read","judge"] && refusalCode == ExitSuccess)
    (malformed,_,malformedCode) <- broker NonFinite program
    assert "non-finite wire probability accepted" (malformed == Nothing && malformedCode /= ExitSuccess)
    forM_ [MissingAnswer,ExtraAnswer,WrongAnswer] $ \scenario -> do
      (bad,_,badCode) <- broker scenario program
      assert "malformed batch assembled" (bad == Just (success (String "InvalidProviderResponse")) && badCode == ExitSuccess)
  putStrLn "Judgement generated tool passed GHC and MicroHs: captured read, typed questions, applicative batch continuation, refusal and finite-number codec."

data Scenario = Normal | Refused | NonFinite | MissingAnswer | ExtraAnswer | WrongAnswer deriving Eq

recording :: Scenario -> Eff (Judgement : es) a -> Eff es a
recording scenario = interpret $ \_ (Judge (JudgementRequest _ questions)) -> pure $
  if scenario == Refused then Left RateLimited else Right (alter (map answer questions))
  where
    alter :: [JudgementAnswer] -> [JudgementAnswer]
    alter values = case scenario of
      MissingAnswer -> drop 1 values
      ExtraAnswer -> values ++ values
      WrongAnswer -> reverse values
      _ -> values
    answer (YesNoRequest _ _ _) = YesNoResult (YesNoAnswer (if scenario == NonFinite then 0/0 else 0.95))
    answer (ChoiceRequest _ options) = ChoiceResult (ChoiceAnswer "Urgent" (zip (map fst options) [0.05,0.05,0.9]) 0.8)
    answer (ScaleRequest _ levels) = ScaleResult (ScaleAnswer 1.25 (zip [0 .. toInteger (length levels) - 1] [0,0.75,0.25]) 0.7)

broker :: Scenario -> CreateProcess -> IO (Maybe Value,[String],ExitCode)
broker scenario program = do
  result <- timeout 20000000 $ withCreateProcess program { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe } $ \input output errors process ->
    case (input,output,errors) of
      (Just toGuest,Just fromGuest,Just diagnostics) -> do
        let emit bytes = hPutStrLn toGuest (Text.unpack (Text.decodeUtf8 bytes)) >> hFlush toGuest
            loop trace = do
              eof <- hIsEOF fromGuest
              if eof then pure (Nothing,trace) else do
                line <- Text.encodeUtf8 . Text.pack <$> hGetLine fromGuest
                frame <- right (decodeToolFrame line)
                case frame of
                  Completed value -> pure (Just value,trace)
                  HostRequest identity call -> do
                    assert "request order" (identity == toInteger (length trace + 1))
                    (label,reply) <- case call of
                      ToolCall _ _ _ _ value -> do
                        assert "captured-read argument" (value == String "item")
                        pure ("read",success (String "captured 雪"))
                      ToolJudgement request@(JudgementRequest context questions) -> do
                        assert "captured context lost" (context == Context "captured 雪")
                        assert "questions not batched" (length questions == 3)
                        let reply = runPureEff (recording scenario (judge request))
                        pure ("judge",encodeReply reply)
                    emit (encodeResponse identity reply)
                    loop (trace ++ [label])
        emit (Lazy.toStrict (encode (String "item")))
        (value,trace) <- loop []
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
