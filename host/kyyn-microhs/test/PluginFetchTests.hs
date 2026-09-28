{-# LANGUAGE OverloadedStrings, GADTs #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value(..), eitherDecodeStrict, encode, object, (.=), (.:), toJSON)
import Data.Aeson.Types (parseEither, withObject)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Version (showVersion)
import Data.IORef (IORef, newIORef, readIORef, writeIORef, modifyIORef')
import Effectful (runEff, Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import qualified Kyyn.Domain.Secret as Secret
import qualified Kyyn.Plumbing.Capability.SecretStore as Secrets
import qualified Kyyn.Plumbing.Capability.HttpTransport as Http
import qualified Kyyn.Plumbing.Capability.PluginInteraction as Interaction
import qualified Kyyn.Plumbing.Protocol.PluginHost as Host
import qualified Kyyn.Porcelain.Protocol.PluginHost as Host
import Kyyn.Domain.DataType (DataType(..))
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Path
import Kyyn.MicroHs.Inspection (inspectDataType)
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Protocol.PluginInvocation
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import System.Directory (createDirectoryIfMissing, findExecutable)
import System.Environment (getEnv, getArgs)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.Info (compilerVersion)
import System.IO (hGetLine, hPutStrLn, hFlush, hClose, hIsEOF, hGetContents)
import System.IO.Temp (withSystemTempDirectory)
import System.Process
import System.Timeout (timeout)
import PluginNativeTests (nativeTests)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

main :: IO ()
main = do
  args <- getArgs
  if args == ["--network-only"] then networkTests else folderTests >> networkTests

folderTests :: IO ()
folderTests = withSystemTempDirectory "kyyn-plugin-fetch-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  nativeCompiler <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe
    (fail "The matching versioned GHC executable is required for the plugin boundary proof") pure
  let path = either error id . relativePath
      load base file = (,) (path file) <$> Bytes.readFile (repo </> base </> file)
  common <- sequence ([load "shared/kyyn-types/src" ("Kyyn/Types/" ++ name ++ ".hs") |
      name <- ["Evidence","Program","Plugin"]] ++
    [load "guest/kyyn-sdk/src" "Kyyn/Plugin.hs"] ++
    [load "guest/kyyn-runtime/src" ("Kyyn/Runtime/" ++ name ++ ".hs") | name <- ["Json","Plugin"]] ++
    [load "vendor/json" name | name <- ["Text/JSON/Types.hs","Text/JSON/String.hs"]] ++
    [load "host/kyyn-microhs/test/plugin" "FolderSchema.hs"])
  let schemaDirectory = temporary </> "schema"
  writeSources schemaDirectory common
  (config,_) <- inspectDataType toolchain [schemaDirectory] "FolderSchema.Config" >>= right
  (payload,_) <- inspectDataType toolchain [schemaDirectory] "FolderSchema.Document" >>= right
  (options,_) <- inspectDataType toolchain [schemaDirectory] "FolderSchema.FetchOptions" >>= right
  folder <- load "host/kyyn-microhs/test/plugin" "Folder.hs"
  view <- load "host/kyyn-microhs/test/plugin" "ReadDocument.hs"
  optionFixture <- load "host/kyyn-microhs/test/plugin" "Options.hs"
  optionSources <- right (acquisitionSources config payload (Just options) "Options.fetch" (optionFixture:common))
  (optionPrograms,_) <- compileBoth temporary toolchain nativeCompiler "options" optionSources
  forM_ optionPrograms $ \program -> forM_
    [(object ["tag" .= ("None" :: String)],"default options"),
     (object ["tag" .= ("Some" :: String),"value" .= object ["label" .= ("scoped 🦋" :: String)]],"scoped 🦋")] $
    \(selected,message) -> do
      (result,trace,status) <- broker Normal program (object
        ["arguments" .= object ["config" .= object ["directory" .= ("/folder" :: String),"recursive" .= True],
          "options" .= selected],"snapshot" .= ("prior" :: String)])
      assert "typed options/default did not reach acquisition unchanged"
        (result == Just (failure message) && null trace && status == ExitSuccess)
  acquisition <- right (acquisitionSources config payload Nothing "Folder.fetch" (folder:common))
  captured <- right (capturedReadSources StringType payload StringType "ReadDocument.view" (view:common))
  forM_ ["KyynPluginBindings.hs","KyynPluginEntry.hs","KyynPluginPayloadCodec.hs"] $ \name ->
    assert "generated adapter overwrote authored source" (case acquisitionSources config payload Nothing "Folder.fetch" ((path name,"collision"):folder:common) of
      Left _ -> True; Right _ -> False)
  (fetchPrograms,artifact) <- compileBoth temporary toolchain nativeCompiler "fetch" acquisition
  (readPrograms,_) <- compileBoth temporary toolchain nativeCompiler "read" captured
  let configValue directory = object ["directory" .= (directory :: String),"recursive" .= True]
      input arguments = object ["arguments" .= arguments,"snapshot" .= ("prior" :: String)]
      expected = success (toJSON
        [change "Updated" "changed.txt" "changed 🦋\nline two",change "New" "new.txt" "new",
         object ["tag" .= ("Removed" :: String),"value" .= ("gone.txt" :: String)]])
  forM_ fetchPrograms $ \program -> do
    (result,trace,status) <- broker Normal program (input (configValue "/folder"))
    assert "acquisition delta differs between compilers" (result == Just expected && status == ExitSuccess)
    assert "acquisition did not suspend for typed evidence reads"
      (length [() | ("evidence","read") <- trace] == 3 && ("files","list") `elem` trace)
    (relative,relativeTrace,relativeStatus) <- broker Normal program (input (configValue "relative"))
    assert "relative directory caused host effects" (relative == Just (failure "Folder directory must be absolute") && null relativeTrace && relativeStatus == ExitSuccess)
    (unreadable,unreadableTrace,unreadableStatus) <- broker DirectoryFailure program (input (configValue "/folder"))
    assert "failed enumeration became removals" (unreadable == Just (failure "Directory unreadable") &&
      unreadableTrace == [("files","list")] && unreadableStatus == ExitSuccess)
    (readFailure,_,readFailureStatus) <- broker FileFailure program (input (configValue "/folder"))
    assert "failed file read produced a successful delta" (readFailure == Just (failure "File unreadable") && readFailureStatus == ExitSuccess)
    forM_ [WrongId,WrongPayload] $ \scenario -> do
      (bad,_,badStatus) <- broker scenario program (input (configValue "/folder"))
      assert "malformed host reply resumed a continuation" (bad == Nothing && badStatus /= ExitSuccess)
  forM_ readPrograms $ \program -> do
    (result,trace,status) <- broker Normal program (input (String "changed.txt"))
    assert "captured read requested acquisition or lost payload" (result == Just (success (String "old")) &&
      trace == [("evidence","read")] && status == ExitSuccess)
  let forbidden = Text.encodeUtf8 (Text.unlines ["module ReadDocument where","import KyynPluginBindings",
        "import qualified FolderSchema as Schema",
        "view :: String -> EvidenceSnapshot Schema.Document -> CapturedRead (Either FetchError String)",
        "view path _ = readTextFile path"])
  forbiddenSources <- right (capturedReadSources StringType payload StringType "ReadDocument.view" ((path "ReadDocument.hs",forbidden):common))
  rejectBoth temporary toolchain nativeCompiler forbiddenSources
  nativeTests temporary toolchain config payload artifact
  putStrLn "Plugin acquisition/captured-read adapters passed under GHC and MicroHs with real request/response pipes."

writeSources :: FilePath -> [(RelativePath,Bytes.ByteString)] -> IO ()
writeSources directory sources = forM_ sources $ \(path,bytes) -> do
  let target = directory </> relativeName path
  createDirectoryIfMissing True (takeDirectory target)
  Bytes.writeFile target bytes

compileBoth :: FilePath -> FilePath -> FilePath -> String -> GuestSources -> IO ([CreateProcess],CompiledProgram)
compileBoth temporary toolchain ghc label sources = do
  let directory = temporary </> label
      executable = directory </> "native"
  writeSources directory (sourceFiles sources)
  (status,out,err) <- readProcessWithExitCode ghc ["-v0","-fforce-recomp","-i" ++ directory,
    "-outputdir",directory </> "objects","-main-is","KyynPluginEntry.main",
    directory </> relativeName (selectedEntry sources),"-o",executable] ""
  assert ("GHC rejected generated plugin: " ++ out ++ err) (status == ExitSuccess)
  artifact <- compileMicroHs temporary toolchain sources >>= right
  let CompiledProgram _ (_,bytes) = artifact
      program = directory </> "program.comb"
  Bytes.writeFile program bytes
  pure ([proc executable [],proc (toolchain </> "bin/mhseval") ["+RTS","-r" ++ program,"-RTS"]],artifact)

compileMicroHs :: FilePath -> FilePath -> GuestSources -> IO (Either [Diagnostic] CompiledProgram)
compileMicroHs temporary toolchain sources = do
  scope <- right (directoryScope temporary)
  compiler <- GuestToolchain <$> right (directoryScope toolchain)
  runEff (runFailure (runProcessExecutionIO (runFileSystemIO scope (runGuestCompilation compiler Nothing (compileGuest sources))))) >>= right

rejectBoth :: FilePath -> FilePath -> FilePath -> GuestSources -> IO ()
rejectBoth temporary toolchain ghc sources = do
  let directory = temporary </> "forbidden"
  writeSources directory (sourceFiles sources)
  (status,_,_) <- readProcessWithExitCode ghc ["-v0","-fno-code","-i" ++ directory,
    "-outputdir",directory </> "objects",directory </> relativeName (selectedEntry sources)] ""
  assert "GHC granted a capability outside the declared row" (status /= ExitSuccess)
  rejected <- compileMicroHs temporary toolchain sources
  assert "MicroHs granted a capability outside the declared row" (case rejected of Left _ -> True; Right _ -> False)

data Scenario = Normal | DirectoryFailure | FileFailure | WrongId | WrongPayload deriving (Eq)

broker :: Scenario -> CreateProcess -> Value -> IO (Maybe Value,[(String,String)],ExitCode)
broker scenario = brokerWith scenario (respond scenario)

brokerWith :: Scenario -> (String -> String -> Value -> IO Value) -> CreateProcess -> Value -> IO (Maybe Value,[(String,String)],ExitCode)
brokerWith scenario respondTo program input = do
  result <- timeout 20000000 $ withCreateProcess program {std_in = CreatePipe,std_out = CreatePipe,std_err = CreatePipe} $ \stdin stdout stderr process ->
    case (stdin,stdout,stderr) of
      (Just toGuest,Just fromGuest,Just errors) -> do
        let emit value = hPutStrLn toGuest (Text.unpack (Text.decodeUtf8 (Lazy.toStrict (encode value)))) >> hFlush toGuest
            loop trace = do
              done <- hIsEOF fromGuest
              if done then pure (Nothing,trace) else do
                line <- hGetLine fromGuest
                message <- right (eitherDecodeStrict (Text.encodeUtf8 (Text.pack line)))
                tag <- right (parseEither (withObject "frame" (.: "tag")) message)
                case tag :: String of
                  "Completed" -> do
                    output <- right (parseEither (withObject "completed" (.: "result")) message)
                    pure (Just output,trace)
                  "HostRequest" -> do
                    (identity,capability,method,args) <- right (parseEither (withObject "request" $ \fields ->
                      (,,,) <$> fields .: "id" <*> fields .: "capability" <*> fields .: "method" <*> fields .: "arguments") message)
                    assert "request IDs are not sequential" (identity == show (length trace + 1))
                    answer <- respondTo capability method args
                    emit (object ["tag" .= ("HostResponse" :: String),"id" .=
                      (if scenario == WrongId then "wrong" else identity),"result" .=
                      (if scenario == WrongPayload then success (Bool True) else answer)])
                    loop (trace ++ [(capability,method)])
                  _ -> fail "Unknown guest frame"
        emit input
        (output,trace) <- loop []
        hClose toGuest
        diagnostics <- hGetContents errors
        length diagnostics `seq` pure ()
        status <- waitForProcess process
        pure (output,trace,status)
      _ -> fail "Missing test protocol pipes"
  maybe (fail "Plugin protocol timed out") pure result

respond :: Scenario -> String -> String -> Value -> IO Value
respond scenario capability method arguments = case (capability,method) of
  ("files","list") -> do
    (directory,recursive) <- right (parseEither (withObject "list files" $ \fields -> (,) <$> fields .: "directory" <*> fields .: "recursive") arguments)
    assert "configuration not passed through the guest" (directory == ("/folder" :: String) && recursive)
    pure (if scenario == DirectoryFailure then failure "Directory unreadable" else success (toJSON ["changed.txt","same.txt","new.txt" :: String]))
  ("files","read") -> do
    path <- right (parseEither (withObject "read file" (.: "path")) arguments)
    contents <- maybe (fail "Unexpected file path") pure (lookup (path :: String)
      [("/folder/changed.txt","changed 🦋\nline two"),("/folder/same.txt","same"),("/folder/new.txt","new")])
    pure (if scenario == FileFailure then failure "File unreadable" else success
      (object ["contents" .= (contents :: Text.Text),"fingerprint" .= ("recorded-" <> contents)]))
  ("evidence","list") -> do
    checkSnapshot arguments
    pure (success (toJSON ["gone.txt","changed.txt","same.txt" :: String]))
  ("evidence","read") -> do
    checkSnapshot arguments
    key <- right (parseEither (withObject "read evidence" (.: "id")) arguments)
    contents <- maybe (fail "Unexpected evidence ID") pure (lookup key
      [("gone.txt","gone"),("changed.txt","old"),("same.txt","same")])
    pure (success (object ["tag" .= ("Some" :: String),"value" .= evidence key contents]))
  _ -> fail "Guest requested a capability outside the fixture's row"
  where
    checkSnapshot value = do
      snapshot <- right (parseEither (withObject "snapshot" (.: "snapshot")) value)
      assert "guest lost its explicit prior snapshot handle" (snapshot == ("prior" :: String))

success :: Value -> Value
success value = object ["tag" .= ("Right" :: String),"value" .= value]
failure :: String -> Value
failure message = object ["tag" .= ("Left" :: String),"value" .= message]
evidence :: String -> Text.Text -> Value
evidence key contents = object ["fingerprint" .= ("recorded-" <> contents),
  "references" .= ["/folder/" ++ key],"payload" .= object ["text" .= contents]]
change :: String -> String -> Text.Text -> Value
change kind key contents = object ["tag" .= kind,"value" .= object ["id" .= key,"evidence" .= evidence key contents]]

networkTests :: IO ()
networkTests = withSystemTempDirectory "kyyn-plugin-network-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  compiler <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe (fail "Matching GHC required") pure
  let path = either error id . relativePath
      load base file = (,) (path file) <$> Bytes.readFile (repo </> base </> file)
  common <- sequence ([load "shared/kyyn-types/src" ("Kyyn/Types/" ++ name ++ ".hs") |
      name <- ["Evidence","Program","Plugin","PluginHost"]] ++
    [load "guest/kyyn-sdk/src" "Kyyn/Plugin/Host.hs"] ++
    [load "guest/kyyn-runtime/src" ("Kyyn/Runtime/" ++ name ++ ".hs") | name <- ["Json","Plugin","PluginHost"]] ++
    [load "vendor/json" name | name <- ["Text/JSON/Types.hs","Text/JSON/String.hs"]])
  fixture <- Bytes.readFile (repo </> "host/kyyn-microhs/test/plugin/Network.hs")
  sources <- right (guestSources (path "KyynPluginEntry.hs") ((path "KyynPluginEntry.hs",fixture):common))
  (programs,_) <- compileBoth temporary toolchain compiler "network" sources
  forM_ programs $ \program -> do
    secret <- newIORef Nothing
    displays <- newIORef []
    let respondTo capability method arguments = do
          call <- right (parseEither (Host.decodePluginHostCall capability method) arguments)
          runEff (runFailure (recordHttp (recordSecrets secret (recordWait (recordLogin displays (Host.answerLogin call)))))) >>= right
    (result,trace,status) <- brokerWith Normal respondTo program (object [])
    assert "network guest result" (result == Just (success (String "complete")) && status == ExitSuccess)
    assert "network guest order" (trace == [("secrets","get"),("login","display"),("waiting","seconds"),
      ("secrets","put"),("secrets","get"),("http","send")])
    messages <- readIORef displays
    assert "explicit instructions" (messages == ["Open the fixture URL; code 雪"])
    forM_ [WrongId,WrongPayload] $ \scenario -> do
      (invalid,_,exit) <- brokerWith scenario respondTo program (object [])
      assert "bad network reply resumed" (invalid == Nothing && exit /= ExitSuccess)
    denied <- runEff (runFailure (recordHttp (recordSecrets secret (recordWait
      (Host.answerNetwork (Host.DisplayInstructions "must not display"))))))
    assert "acquisition permitted interaction" (case denied of Left _ -> True; _ -> False)
  forM_ ["-1","01","1.0","99999999999999999999999999"] $ \seconds ->
    assert "invalid wait accepted" (case parseEither (Host.decodePluginHostCall "waiting" "seconds")
      (object ["seconds" .= (seconds :: String)]) of Left _ -> True; Right _ -> False)
  let forbidden = Text.encodeUtf8 (Text.unlines ["module KyynPluginEntry where","import Kyyn.Plugin.Host",
        "main :: IO ()","main = pure ()","bad :: NetworkAcquisition String ()","bad = displayInstructions \"no\""])
  rejectBoth temporary toolchain compiler =<< right
    (guestSources (path "KyynPluginEntry.hs") ((path "KyynPluginEntry.hs",forbidden):common))
  putStrLn "Network requests, secret rotation and explicit login passed under GHC and MicroHs."

recordHttp :: Eff (Http.HttpTransport : es) a -> Eff es a
recordHttp = interpret $ \_ (Http.SendHttp request) ->
  if request == Http.HttpRequest "POST" "https://fixture.test/token" [("Authorization","rotated 雪")] "body 雪"
  then pure (Right (Http.HttpResponse 429 [("Retry-After","2")] "response 雪"))
  else error "Unexpected HTTP request"

recordSecrets :: IOE :> es => IORef (Maybe Text.Text) -> Eff (Secrets.SecretStore : es) a -> Eff es a
recordSecrets saved = interpret $ \_ call -> case call of
  Secrets.ReadSecret name -> do
    value <- liftIO (readIORef saved)
    pure (if Secret.secretNameText name == "refresh" then maybe (Left (Secret.SecretNotFound name)) Right value
      else Left (Secret.SecretNotFound name))
  Secrets.WriteSecret _ value -> liftIO (writeIORef saved (Just value))
  _ -> error "Unexpected secret operation"

recordWait :: Eff (Interaction.Waiting : es) a -> Eff es a
recordWait = interpret $ \_ (Interaction.WaitSeconds n) -> if n == 0 then pure () else error "Unexpected wait"

recordLogin :: IOE :> es => IORef [String] -> Eff (Interaction.LoginInteraction : es) a -> Eff es a
recordLogin messages = interpret $ \_ (Interaction.DisplayInstructions value) -> liftIO (modifyIORef' messages (++ [value]))
