-- GHC/MicroHs pipe tests for typed acquisition and captured reads, plus native
-- broker/store fixtures: delta publication, failure preservation and snapshot reuse.
-- --network-only selects HTTP/secrets/wait/login frames; no live provider.

{-# LANGUAGE OverloadedStrings, GADTs #-}
module PluginFetchTests (main, compileBoth, brokerWith, Scenario(..)) where

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
import qualified Kyyn.Plumbing.Protocol.Frame as Wire
import Kyyn.Domain.DataType (DataType(..))
import Kyyn.Domain.Plugin (PluginEntryKind(..), PluginSignature(..))
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Path
import Kyyn.MicroHs.Inspection (inspectDataType, inspectPluginSignature)
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
import System.FilePath ((</>), takeDirectory, dropExtension)
import System.Info (compilerVersion)
import System.IO (hFlush, hClose, hIsEOF, hGetContents, hSetBinaryMode)
import System.IO.Temp (withSystemTempDirectory)
import System.Process
import System.Timeout (timeout)
import PluginNativeTests (nativeTests, statefulTests)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

main :: IO ()
main = do
  args <- getArgs
  if args == ["--network-only"] then networkTests
  else if args == ["--blobs-only"] then blobTests
  else folderTests >> networkTests >> blobTests

blobTests :: IO ()
blobTests = withSystemTempDirectory "kyyn-plugin-blobs-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  compiler <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe (fail "Matching GHC required") pure
  let path = either error id . relativePath
      load base file = (,) (path file) <$> Bytes.readFile (repo </> base </> file)
  common <- sequence ([load "shared/kyyn-types/src" ("Kyyn/Types/" ++ name ++ ".hs") |
      name <- ["Evidence","Program","Plugin","PluginHost","Blob"]] ++
    [load "guest/kyyn-sdk/src" name | name <- ["Kyyn/Plugin.hs","Kyyn/Plugin/Host.hs"]] ++
    [load "guest/kyyn-runtime/src" ("Kyyn/Runtime/" ++ name ++ ".hs") | name <- ["Json","Transport","Plugin","PluginHost"]] ++
    [load "vendor/json" name | name <- ["Text/JSON/Types.hs","Text/JSON/String.hs"]])
  let ref = object ["sha256" .= replicate 64 'a',"size" .= ("256" :: String),
        "mediaType" .= ("application/octet-stream" :: String),"name" .= object ["tag" .= ("None" :: String)]]
      input value = object ["arguments" .= value,"snapshot" .= ("captured" :: String)]
      handler raw capability method _ = do
        assert "blob request had unexpected raw body" (Bytes.null raw)
        case (capability,method) of
          ("blobs","store") -> pure (success (object ["status" .= ("200" :: String),"headers" .= ([] :: [Value]),
            "blob" .= object ["tag" .= ("Some" :: String),"value" .= ref]]),Bytes.empty)
          ("blobs","read") -> pure (success (object []),Bytes.pack [0..255])
          _ -> fail "Unexpected blob capability"
  forM_ [("BlobCapture",input (String "https://fixture.test/blob"),success ref,[("blobs","store")]),
         ("BlobRead",input ref,success (String "binary, not UTF-8"),replicate 2 ("blobs","read"))] $ \(label,argument,expected,expectedTrace) -> do
    fixture <- Bytes.readFile (repo </> "host/kyyn-microhs/test/plugin" </> label ++ ".hs")
    sources <- right (guestSources (path "KyynPluginEntry.hs") ((path "KyynPluginEntry.hs",fixture):common))
    (programs,_) <- compileBoth temporary toolchain compiler label sources
    forM_ programs $ \program -> do
      (result,trace,status) <- brokerWith Normal handler program argument
      assert (label ++ " failed") (result == Just expected && trace == expectedTrace && status == ExitSuccess)
  putStrLn "Blob acquisition metadata and binary captured reads passed under GHC and MicroHs."

folderTests :: IO ()
folderTests = withSystemTempDirectory "kyyn-plugin-fetch-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  nativeCompiler <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe
    (fail "The matching versioned GHC executable is required for the plugin boundary proof") pure
  let path = either error id . relativePath
      load base file = (,) (path file) <$> Bytes.readFile (repo </> base </> file)
  common <- sequence ([load "shared/kyyn-types/src" ("Kyyn/Types/" ++ name ++ ".hs") |
      name <- ["Evidence","Program","Plugin","PluginHost","Blob"]] ++
    [load "guest/kyyn-sdk/src" name | name <- ["Kyyn/Plugin.hs","Kyyn/Plugin/Host.hs"]] ++
    [load "guest/kyyn-runtime/src" ("Kyyn/Runtime/" ++ name ++ ".hs") | name <- ["Json","Transport","Plugin","PluginHost"]] ++
    [load "vendor/json" name | name <- ["Text/JSON/Types.hs","Text/JSON/String.hs"]] ++
    [load "host/kyyn-microhs/test/plugin" name | name <- ["FolderSchema.hs","SignatureCases.hs"]])
  let schemaDirectory = temporary </> "schema"
  writeSources schemaDirectory common
  (config,_) <- inspectDataType toolchain [schemaDirectory] "FolderSchema.Config" >>= right
  (payload,_) <- inspectDataType toolchain [schemaDirectory] "FolderSchema.Document" >>= right
  (options,_) <- inspectDataType toolchain [schemaDirectory] "FolderSchema.FetchOptions" >>= right
  (box,_) <- inspectDataType toolchain [schemaDirectory] "SignatureCases.Payload" >>= right
  forM_ [(AcquisitionEntry,"good",FetchSignature config Nothing box),
         (AcquisitionEntry,"goodOptions",FetchSignature config (Just options) box),
         (AcquisitionEntry,"goodStateful",StatefulFetchSignature config Nothing box StringType),
         (AcquisitionEntry,"goodStatefulOptions",StatefulFetchSignature config (Just options) box StringType),
         (CapturedReadEntry,"goodRead",ReadSignature StringType box StringType)] $ \(kind,name,expectedSignature) -> do
    (actual,_) <- inspectPluginSignature toolchain [schemaDirectory] kind ("SignatureCases." ++ name) >>= right
    assert ("Wrong derived signature for " ++ name) (actual == expectedSignature)
  forM_ ["badRow","badResult","badPayload","badChange","badOptions","badPosition","badContext","badPolymorphic","badHelper","badArity","badFailure","absent"] $ \name -> do
    inspected <- inspectPluginSignature toolchain [schemaDirectory] AcquisitionEntry ("SignatureCases." ++ name)
    assert ("Accepted malformed signature " ++ name) (case inspected of
      Left problem -> Text.pack ("SignatureCases." ++ name) `Text.isInfixOf` Text.pack (show problem) && "Expected:" `Text.isInfixOf` Text.pack (show problem)
      Right _ -> False)
    if name == "badHelper" then assert "Constrained registered entry lost its concrete-type diagnostic"
      ("concrete types and no residual constraints" `Text.isInfixOf` Text.pack (show inspected)) else pure ()
  genericSources <- right (acquisitionSources config box Nothing "SignatureCases.good" common)
  _ <- compileBoth temporary toolchain nativeCompiler "generic-helper" genericSources
  forM_ [("goodStateful",Nothing),("goodStatefulOptions",Just options)] $ \(entry,selectedOptions) -> do
    sources <- right (statefulAcquisitionSources config box selectedOptions StringType ("SignatureCases." ++ entry) common)
    (programs,artifact) <- compileBoth temporary toolchain nativeCompiler entry sources
    if entry == "goodStateful" then statefulTests temporary toolchain config box artifact else pure ()
    forM_ programs $ \program -> forM_ [Nothing,Just ("saved" :: String)] $ \prior -> do
      let optional = maybe (object ["tag" .= ("None" :: String)])
            (\value -> object ["tag" .= ("Some" :: String),"value" .= value]) prior
          configValue = object ["directory" .= ("/folder" :: String),"recursive" .= True]
          arguments = case selectedOptions of
            Nothing -> configValue
            Just _ -> object ["config" .= configValue,"options" .= object ["tag" .= ("None" :: String)]]
      (result,trace,status) <- broker Normal program (object ["arguments" .= object
        ["input" .= arguments,"startedAt" .= ("2026-10-07T12:00:00Z" :: String),"priorPosition" .= optional],
        "snapshot" .= ("prior" :: String)])
      assert "typed fetch context/result did not round trip" (result == Just (success (object
        ["changes" .= ([] :: [Value]),"position" .= (maybe "first" id prior ++ ":2026-10-07T12:00:00Z")]))
        && null trace && status == ExitSuccess)
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
  captured <- right (capturedReadSources StringType payload TextType "ReadDocument.view" (view:common))
  forM_ ["KyynPluginEntry.hs","KyynPluginPayloadCodec.hs"] $ \name ->
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
    (restored,_,restoredStatus) <- broker TruncatedPayload program (input (configValue "/folder"))
    let restoration = object ["tag" .= ("SetPayload" :: String),"value" .= object
          ["id" .= ("same.txt" :: String),"fingerprint" .= ("recorded-same" :: String),
           "payload" .= object ["tag" .= ("Available" :: String),"value" .= object ["text" .= ("same" :: String)]]]]
    assert "same-version truncated content was not restored" (restoredStatus == ExitSuccess && restored == Just (success (toJSON
      [change "Updated" "changed.txt" "changed 🦋\nline two",restoration,change "New" "new.txt" "new",
       object ["tag" .= ("Removed" :: String),"value" .= ("gone.txt" :: String)]])))
    (empty,emptyTrace,emptyStatus) <- broker Normal program (input (configValue ""))
    assert "empty directory caused host effects" (empty == Just (failure "Folder directory must be nonempty") && null emptyTrace && emptyStatus == ExitSuccess)
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
    (truncated,_,truncatedStatus) <- broker TruncatedPayload program (input (String "changed.txt"))
    assert "truncated read silently returned content" (truncated == Just (failure "Payload truncated") && truncatedStatus == ExitSuccess)
  let forbidden = Text.encodeUtf8 (Text.unlines ["module ReadDocument where","import Kyyn.Plugin","import Kyyn.Plugin.Host",
        "import qualified FolderSchema as Schema",
        "view :: String -> EvidenceSnapshot Schema.Document -> CapturedRead Schema.Document (Either FetchError String)",
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
    "-outputdir",directory </> "objects","-main-is",dropExtension (relativeName (selectedEntry sources)) ++ ".main",
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

data Scenario = Normal | DirectoryFailure | FileFailure | WrongId | WrongPayload | TruncatedPayload deriving (Eq)

broker :: Scenario -> CreateProcess -> Value -> IO (Maybe Value,[(String,String)],ExitCode)
broker scenario = brokerWith scenario (\body capability method args -> do
  assert "non-HTTP request has a raw body" (Bytes.null body)
  (,Bytes.empty) <$> respond scenario capability method args)

brokerWith :: Scenario -> (Bytes.ByteString -> String -> String -> Value -> IO (Value,Bytes.ByteString)) -> CreateProcess -> Value -> IO (Maybe Value,[(String,String)],ExitCode)
brokerWith scenario respondTo program input = do
  result <- timeout 20000000 $ withCreateProcess program {std_in = CreatePipe,std_out = CreatePipe,std_err = CreatePipe} $ \stdin stdout stderr process ->
    case (stdin,stdout,stderr) of
      (Just toGuest,Just fromGuest,Just errors) -> do
        hSetBinaryMode toGuest True
        hSetBinaryMode fromGuest True
        let emit value body = mapM_ (Bytes.hPut toGuest) (Wire.encodeFrame (Wire.Frame (Lazy.toStrict (encode value)) body)) >> hFlush toGuest
            next = do
              bytes <- Bytes.hGetSome fromGuest 32768
              pure (if Bytes.null bytes then Nothing else Just bytes)
            loop buffered trace = do
              done <- hIsEOF fromGuest
              if done && Bytes.null buffered then pure (Nothing,trace) else do
                (Wire.Frame metadata body,rest) <- Wire.readFrame next buffered >>= right
                message <- right (eitherDecodeStrict metadata)
                tag <- right (parseEither (withObject "frame" (.: "tag")) message)
                case tag :: String of
                  "Completed" -> do
                    assert "terminal result has a raw body" (Bytes.null body)
                    output <- right (parseEither (withObject "completed" (.: "result")) message)
                    pure (Just output,trace)
                  "HostRequest" -> do
                    (identity,capability,method,args) <- right (parseEither (withObject "request" $ \fields ->
                      (,,,) <$> fields .: "id" <*> fields .: "capability" <*> fields .: "method" <*> fields .: "arguments") message)
                    assert "request IDs are not sequential" (identity == show (length trace + 1))
                    (answer,responseBody) <- respondTo body capability method args
                    emit (object ["tag" .= ("HostResponse" :: String),"id" .=
                      (if scenario == WrongId then "wrong" else identity),"result" .=
                      (if scenario == WrongPayload then success (Bool True) else answer)]) responseBody
                    loop rest (trace ++ [(capability,method)])
                  _ -> fail "Unknown guest frame"
        emit input Bytes.empty
        (output,trace) <- loop Bytes.empty []
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
      (object ["contents" .= (contents :: Text.Text),"fingerprint" .= ("recorded-" <> contents),"path" .= path]))
  ("evidence","list") -> do
    checkSnapshot arguments
    pure (success (toJSON ["gone.txt","changed.txt","same.txt" :: String]))
  ("evidence","read") -> do
    checkSnapshot arguments
    key <- right (parseEither (withObject "read evidence" (.: "id")) arguments)
    contents <- maybe (fail "Unexpected evidence ID") pure (lookup key
      [("gone.txt","gone"),("changed.txt","old"),("same.txt","same")])
    let captured = if scenario == TruncatedPayload then object
          ["fingerprint" .= ("recorded-" <> contents),"externalReferences" .= ["/folder/" ++ key],
           "payload" .= object ["tag" .= ("Truncated" :: String)]] else evidence key contents
    pure (success (object ["tag" .= ("Some" :: String),"value" .= captured]))
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
  "externalReferences" .= ["/folder/" ++ key],"payload" .= object ["tag" .= ("Available" :: String),"value" .= object ["text" .= contents]]]
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
      name <- ["Evidence","Program","Plugin","PluginHost","Blob"]] ++
    [load "guest/kyyn-sdk/src" "Kyyn/Plugin/Host.hs"] ++
    [load "guest/kyyn-runtime/src" ("Kyyn/Runtime/" ++ name ++ ".hs") | name <- ["Json","Transport","Plugin","PluginHost"]] ++
    [load "vendor/json" name | name <- ["Text/JSON/Types.hs","Text/JSON/String.hs"]])
  fixture <- Bytes.readFile (repo </> "host/kyyn-microhs/test/plugin/Network.hs")
  sources <- right (guestSources (path "KyynPluginEntry.hs") ((path "KyynPluginEntry.hs",fixture):common))
  (programs,_) <- compileBoth temporary toolchain compiler "network" sources
  forM_ programs $ \program -> do
    secret <- newIORef Nothing
    displays <- newIORef []
    let respondTo body capability method arguments = do
          call <- right (parseEither (Host.decodePluginHostCall body capability method) arguments)
          runEff (runFailure (recordHttp (recordSecrets secret (recordWait (recordLogin displays (Host.answerLogin call)))))) >>= right
    (result,trace,status) <- brokerWith Normal respondTo program (object [])
    assert "network guest result" (result == Just (success (String "complete")) && status == ExitSuccess)
    assert "network guest order" (trace == [("secrets","get"),("login","display"),("waiting","seconds"),
      ("secrets","put"),("secrets","get")] ++ replicate 4 ("http","send"))
    messages <- readIORef displays
    assert "explicit instructions" (messages == ["Open the fixture URL; code 雪"])
    forM_ [WrongId,WrongPayload] $ \scenario -> do
      (invalid,_,exit) <- brokerWith scenario respondTo program (object [])
      assert "bad network reply resumed" (invalid == Nothing && exit /= ExitSuccess)
    denied <- runEff (runFailure (recordHttp (recordSecrets secret (recordWait
      (Host.answerNetwork (Host.DisplayInstructions "must not display"))))))
    assert "acquisition permitted interaction" (case denied of Left _ -> True; _ -> False)
  forM_ ["-1","01","1.0","99999999999999999999999999"] $ \seconds ->
    assert "invalid wait accepted" (case parseEither (Host.decodePluginHostCall Bytes.empty "waiting" "seconds")
      (object ["seconds" .= (seconds :: String)]) of Left _ -> True; Right _ -> False)
  let forbidden = Text.encodeUtf8 (Text.unlines ["module KyynPluginEntry where","import Kyyn.Plugin.Host",
        "main :: IO ()","main = pure ()","bad :: Acquisition String ()","bad = displayInstructions \"no\""])
  rejectBoth temporary toolchain compiler =<< right
    (guestSources (path "KyynPluginEntry.hs") ((path "KyynPluginEntry.hs",forbidden):common))
  putStrLn "Network requests, secret rotation and explicit login passed under GHC and MicroHs."

recordHttp :: Eff (Http.HttpTransport : es) a -> Eff es a
recordHttp = interpret $ \_ (Http.SendHttp request) ->
  if request == Http.HttpRequest "POST" "https://fixture.test/token" [("Authorization","rotated 雪")] "body 雪"
  then pure (Right (Http.HttpResponse 429 [("Retry-After","2")] "response 雪"))
  else case [problem | problem <- [Http.HttpTimedOut,Http.HttpConnectionFailed,Http.HttpUnavailable],
        request == Http.HttpRequest "GET" ("https://fixture.test/" <> Text.pack (show problem)) [] ""] of
    [problem] -> pure (Left problem)
    _ -> error "Unexpected HTTP request"

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
