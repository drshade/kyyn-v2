-- A real subprocess describes and invokes the same compiled fixture through the
-- host frame codec, including captured-read callbacks and response ID rejection.
-- Nix derivation/source capture is tested separately.
{-# LANGUAGE DeriveAnyClass, DerivingStrategies, DeriveGeneric, OverloadedStrings, TypeApplications, OverloadedRecordDot #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Control.Exception (SomeException, try)
import Data.Aeson (Value(..), object, (.=), encode, eitherDecodeStrict', toJSON)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString.Char8 as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.Either (isLeft)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Types.Plugin (Connector(..), CapturedMethod(..))
import qualified Kyyn.Plugin as Plugin
import Kyyn.Plugin.Host (Acquisition, PluginLogin, LoginError)
import Kyyn.Plugin.Sink (Sink, SinkError)
import Kyyn.Runtime.PluginRegistration (encodeConnectors)
import qualified Kyyn.Domain.Guest as Host
import Data.Fixed (Fixed, E2)
import Data.Functor.Identity (runIdentity)
import GHC.Generics (Generic)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode(..))
import qualified System.Process.Typed as Process
import Kyyn.Schema
import Kyyn.Types.Query (Query, CollectionBinding(..), readCollection)
import Kyyn.Types.Diagnostic (ValidationReport(..))
import qualified Kyyn.Types.Contract as D
import qualified Kyyn.Types.Guest as G
import Kyyn.Runtime.Guest
import qualified Kyyn.Plumbing.Protocol.Frame as Frame

data Item = Item { amount :: Fixed E2 } deriving stock (Generic) deriving anyclass (Contract)
data Root = Root { items :: [Fact Item] } deriving stock (Generic) deriving anyclass (Contract)

annotations :: SchemaMetadata
annotations = SchemaMetadata [] [] [CollectionDecl "items" "items" []]

total :: () -> Query Root (Fixed E2)
total () = do
  values <- readCollection (CollectionBinding "items" (\root -> root.items))
  pure (sum [item.amount | Fact _ item <- values])

guest :: IO ()
guest = runGuest [G.ModuleDescription "Fixture" "GuestProtocolTests.hs" Nothing []
  [G.ExportDescription "Root" "data Root" "Fixture.Root" (Just "Fixture documentation: café") G.ExportType]]
  [validationEntry @Root annotations ["GuestProtocolTests.hs"] (const (ValidationReport [])),
   queryEntry @Root "total" (annotations,["GuestProtocolTests.hs"])
     (SchemaMetadata [] [] [],[]) (SchemaMetadata [] [] [],[]) total]

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--plugin-guest"] -> pluginGuest
    ["--acquisition-guest"] -> acquisitionGuest
    ["--captured-guest"] -> capturedGuest
    ["--guest"] -> guest
    ["--captured-built",path] -> checkCaptured (path,[]) >> checkAcquisition (path,[]) >> checkPlugin (path,[])
    ["--built",path] -> check (path,[])
    ["--schema-built",path] -> checkSchema (path,[])
    ["--api-built",path] -> checkApi False (path,[])
    ["--api-bindings-built",path] -> checkApi True (path,[])
    [] -> do
      path <- getExecutablePath
      check (path,["--guest"])
      checkCaptured (path,["--captured-guest"])
      checkAcquisition (path,["--acquisition-guest"])
      checkPlugin (path,["--plugin-guest"])
    _ -> fail "Expected --guest or --built EXECUTABLE"

checkApi :: Bool -> (FilePath,[String]) -> IO ()
checkApi withBindings executable = do
  value <- invoke executable (object ["operation" .= ("describe" :: String)])
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  unless (null description.entries) (fail "API discovery produced runnable entries")
  let symbols = [(m.moduleName,e.exportName) | m <- description.modules, e <- m.moduleExports]
  let expected = if withBindings then [("Queries","total"),("KyynQueryBindings","items")]
        else [("Example","answer"),("Data.Maybe","fromMaybe"),("Kyyn.Optics","field")]
  unless (all (`elem` symbols) expected)
    (fail "Authored or installed-library exports missing")
  unless (all ((/= "private") . snd) symbols) (fail "Private implementation exported")
  putStrLn "API discovery inspects selected authored and locked library modules."

checkSchema :: (FilePath,[String]) -> IO ()
checkSchema executable = do
  value <- invoke executable (object ["operation" .= ("describe" :: String)])
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  case description.entries of
    [G.ContractEntry "root" selected] ->
      unless (selected.loadedSources == ["src/Main.hs"]) (fail "Wrong schema-only source closure")
    _ -> fail "Schema discovery produced runnable entries"
  unless (all ((/= "Queries") . G.moduleName) description.modules) (fail "Unfinished query included in schema discovery")
  (status,_,_) <- call executable (object ["operation" .= ("invoke" :: String),"entry" .= ("root" :: String),"argument" .= object []])
  unless (status /= ExitSuccess) (fail "Description-only entry was invokable")
  putStrLn "Schema discovery succeeds independently of unfinished query code."

check :: (FilePath,[String]) -> IO ()
check executable = do
  checkRequests
  checkRegistrations
  unsupported <- try (checkEntries
    [queryEntry @Root @() @Double "unsupported" (annotations,[])
      (SchemaMetadata [] [] [],[]) (SchemaMetadata [] [] [],[]) (const (pure 1.25))]) :: IO (Either SomeException ())
  unless (isLeft unsupported) (fail "Build preflight accepted an unsupported query result contract")
  descriptionValue <- invoke executable (object ["operation" .= ("describe" :: String)])
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode descriptionValue)) :: Either String G.GuestDescription)
  unless (description.protocol == G.protocolIdentity) (fail "Wrong protocol identity")
  _ <- right (Host.checkGuest description)
  unless (isLeft (Host.checkGuest description { G.protocol = "unexpected" })) (fail "Unknown guest protocol accepted")
  unless (isLeft (Host.checkGuest description { G.entries = description.entries ++ description.entries })) (fail "Duplicate entries accepted")
  let changeContracts change = description { G.entries = map (fmap change) description.entries }
  unless (isLeft (Host.checkGuest (changeContracts (\selected -> selected { G.identity = "incorrect" }))))
    (fail "Incorrect contract fingerprint accepted")
  unless (isLeft (Host.checkGuest (changeContracts (\selected -> selected { G.loadedSources = ["../outside.hs"] }))))
    (fail "Source traversal accepted")
  unless (map G.entryName description.entries == ["validate","total"]) (fail "Wrong registered entries")
  selectedRoot <- case [root | G.ValidatorEntry _ root <- description.entries] of
    [root] -> pure root
    _ -> fail "Missing validator contract"
  let malformed entry = object ["protocol" .= G.protocolIdentity,"entries" .= [entry],"modules" .= ([] :: [Value])]
      rejects value = unless (isLeft (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.GuestDescription))
        (fail "Malformed guest description passed the strict reader")
  forM_ [
    object ["entryName" .= ("validate" :: String),"kind" .= ("unknown" :: String),"root" .= selectedRoot],
    object ["entryName" .= ("validate" :: String),"kind" .= ("validator" :: String),"root" .= selectedRoot,
      "capabilities" .= ([] :: [String])],
    object ["entryName" .= ("total" :: String),"kind" .= ("query" :: String),"root" .= selectedRoot,
      "arguments" .= selectedRoot]] (rejects . malformed)
  case toJSON description of
    Object fields -> rejects (Object (Keys.insert "unexpected" Null fields))
    _ -> fail "Description encoder returned a non-object"
  let badExport = G.ExportDescription "Root" "data Root" "Main.Root" Nothing G.ExportType
  case toJSON badExport of
    Object fields -> unless (isLeft (eitherDecodeStrict' (Lazy.toStrict (encode
      (Object (Keys.insert "kind" (String "unknown") fields)))) :: Either String G.ExportDescription))
        (fail "Unknown export kind accepted")
    _ -> fail "Export encoder returned a non-object"
  forM_ description.entries $ \entry -> forM_ entry $ \selected ->
    do
      unless (selected.identity == D.fingerprint (D.contractIdentity selected.structure selected.metadata))
        (fail "Guest description fingerprint disagrees")
      unless ("src/Annotations.hs" `notElem` selected.loadedSources)
        (fail "Metadata-only source included in schema dependency closure")
  forM_ [selected | G.QueryEntry _ (G.QueryContracts _ arguments result) <- description.entries,
       selected <- [arguments,result]] $ \selected ->
    unless (selected.metadata == SchemaMetadata [] [] []) (fail "Root metadata leaked into query arguments or result")
  let root = object ["items" .= [fact "a" "12.34", fact "b" "-2.34"]]
      fact ident amount = object ["id" .= (ident :: String), "value" .= object ["amount" .= (amount :: String)]]
      request name argument = object ["operation" .= ("invoke" :: String), "entry" .= (name :: String), "argument" .= argument]
  report <- invoke executable (request "validate" root)
  unless (report == Array mempty) (fail "Validation did not run")
  result <- invoke executable (request "total" (object ["root" .= root,"arguments" .= object []]))
  case result of
    Object fields -> unless (Keys.lookup "result" fields == Just (String "10")) (fail "Exact sum changed")
    _ -> fail "Invalid query result"
  forM_ [request "missing" root,
    request "validate" (object ["items" .= [fact "a" "12.345"]]),
    object ["operation" .= ("describe" :: String), "argument" .= root]] $ \requestValue -> do
      (status,_,_) <- call executable requestValue
      unless (status /= ExitSuccess) (fail "Malformed invocation accepted")
  putStrLn "Compiled guest describe/invoke and rejection checks passed."

call :: (FilePath,[String]) -> Value -> IO (ExitCode,Lazy.ByteString,Lazy.ByteString)
call (executable,arguments) value = Process.readProcess (Process.setStdin (Process.byteStringInput
  (Lazy.fromStrict (Bytes.concat (Frame.encodeFrame (Frame.jsonFrame (Lazy.toStrict (encode value)))))))
  (Process.proc executable arguments))

invoke :: (FilePath,[String]) -> Value -> IO Value
invoke executable value = do
  (status,output,errors) <- call executable value
  unless (status == ExitSuccess) (fail (show errors))
  (Frame.Frame metadata body,remaining) <- right (runIdentity (Frame.readFrame (pure Nothing) (Lazy.toStrict output)))
  unless (Bytes.null body && Bytes.null remaining) (fail "Unexpected response bytes")
  right (eitherDecodeStrict' metadata)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

-- The bootstrap writer and build-side reader share the same registration codec.
-- Missing/extra fields and JSON null must not weaken declaration checking.
checkRegistrations :: IO ()
checkRegistrations = do
  let source = SourceConnector "Folder" "Folder.fetch" "Folder.validate"
        [CapturedMethod "content" "Read café" "Folder.content"] Nothing
      declarations = [source,SinkConnector "Write" "Writer.validate" "Writer.publish" "Writer.defaults"]
  encoded <- right (encodeConnectors declarations)
  decoded <- right (eitherDecodeStrict' (Text.encodeUtf8 (Text.pack encoded)) :: Either String [Connector])
  unless (decoded == declarations) (fail "Registration bootstrap changed declaration values")
  case toJSON source of
    Object fields -> forM_ [Keys.insert "unknown" (String "extra") fields,Keys.delete "login" fields,
        Keys.insert "login" Null fields] $ \malformed ->
      unless (isLeft (eitherDecodeStrict' (Lazy.toStrict (encode (Object malformed))) :: Either String Connector))
        (fail "Malformed connector registration accepted")
    _ -> fail "Connector registration is not an object"

-- Exercise a callback on the transport already opened for invocation. The
-- supplied host response is consumed only after the guest emits its request.
capturedGuest :: IO ()
capturedGuest = runGuest [] [capturedReadEntry @() @Item @Integer "local-file.Files.count"
  (G.CapturedMethodIdentity "local-file" "Files" "count" "Count captured files") []
  (\() snapshot -> fmap (fmap (toInteger . length)) (Plugin.listEvidenceIds snapshot))]

checkCaptured :: (FilePath,[String]) -> IO ()
checkCaptured executable@(path,args) = do
  descriptionValue <- invoke executable (object ["operation" .= ("describe" :: String)])
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode descriptionValue)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  case [entry | entry@G.CapturedReadEntry{} <- description.entries] of
    [G.CapturedReadEntry "local-file.Files.count" method _] ->
      unless (method.methodName == "count") (fail "Captured method identity changed")
    _ -> fail "Missing captured read entry"
  let rename entry = entry { G.entryName = "another.entry" }
  unless (isLeft (Host.checkGuest description { G.entries = description.entries ++ map rename description.entries }))
    (fail "Duplicate captured method identity accepted")
  forM_ ["", "bad/plugin"] $ \bad -> do
    let invalid entry = case entry of
          G.CapturedReadEntry name method contracts ->
            G.CapturedReadEntry name method { G.pluginName = bad } contracts
          other -> other
    unless (isLeft (Host.checkGuest description { G.entries = map invalid description.entries }))
      (fail "Invalid plugin name in captured description accepted")
  let invocation = toJSON (G.Invoke "local-file.Files.count" (toJSON (G.CapturedInvocation (object []) "snapshot-1")))
      response identity = object ["tag" .= ("HostResponse" :: String),"id" .= (identity :: String),
        "result" .= object ["tag" .= ("Right" :: String),"value" .= (["one","two"] :: [String])]]
      frame value = Bytes.concat (Frame.encodeFrame (Frame.jsonFrame (Lazy.toStrict (encode value))))
      run identity = Process.readProcess (Process.setStdin (Process.byteStringInput
        (Lazy.fromStrict (frame invocation <> frame (response identity)))) (Process.proc path args))
  (status,output,errors) <- run "1"
  unless (status == ExitSuccess) (fail (show errors))
  (Frame.Frame request _,rest) <- right (runIdentity (Frame.readFrame (pure Nothing) (Lazy.toStrict output)))
  requestValue <- right (eitherDecodeStrict' request)
  unless (requestValue == object ["tag" .= ("HostRequest" :: String),"id" .= ("1" :: String),
    "capability" .= ("evidence" :: String),"method" .= ("list" :: String),
    "arguments" .= object ["snapshot" .= ("snapshot-1" :: String)]])
    (fail "Captured invocation emitted the wrong callback")
  (Frame.Frame completed body,remaining) <- right (runIdentity (Frame.readFrame (pure Nothing) rest))
  result <- right (eitherDecodeStrict' completed)
  unless (Bytes.null body && Bytes.null remaining && result == object
    ["tag" .= ("Completed" :: String),"result" .= object ["tag" .= ("Right" :: String),"value" .= ("2" :: String)]])
    (fail "Captured callback did not complete on the same transport")
  (badStatus,_,_) <- run "2"
  unless (badStatus /= ExitSuccess) (fail "Mismatched callback response ID accepted")
  putStrLn "Captured entry describes contracts and exchanges callbacks on the invocation transport."

checkRequests :: IO ()
checkRequests = do
  let requests = [G.Describe,G.Invoke "local-file.Files.count" (toJSON (G.CapturedInvocation (object []) "snapshot-1"))]
  forM_ requests $ \request -> do
    decoded <- right (eitherDecodeStrict' (Lazy.toStrict (encode request)))
    unless (decoded == request) (fail "Shared guest request codec changed its value")
  forM_ [object ["operation" .= ("unknown" :: String)],
    object ["operation" .= ("describe" :: String),"extra" .= True],
    object ["operation" .= ("invoke" :: String),"entry" .= ("local-file.Files.count" :: String)],
    object ["operation" .= ("invoke" :: String),"entry" .= True,"argument" .= object []]] $ \value ->
      unless (isLeft (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.GuestRequest))
        (fail "Malformed shared guest request accepted")
  forM_ [object ["arguments" .= object []],
    object ["arguments" .= object [],"snapshot" .= Null],
    object ["arguments" .= object [],"snapshot" .= ("id" :: String),"extra" .= True]] $ \value ->
      unless (isLeft (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.CapturedInvocation))
        (fail "Malformed shared captured invocation accepted")

acquisitionGuest :: IO ()
acquisitionGuest = runGuest []
  [acquisitionEntry "$acquisition.local-file.Files" (G.ConnectorIdentity "local-file" "Files") [] fetch,
   acquisitionEntry "$acquisition.local-file.Options" (G.ConnectorIdentity "local-file" "Options") [] fetchOptions,
   acquisitionEntry "$acquisition.local-file.State" (G.ConnectorIdentity "local-file" "State") [] fetchState,
   acquisitionEntry "$acquisition.local-file.StateOptions" (G.ConnectorIdentity "local-file" "StateOptions") [] fetchStateOptions]
  where
    fetch :: Integer -> Plugin.EvidenceSnapshot Item -> Acquisition Item (Either Plugin.FetchError [Plugin.EvidenceChange Item])
    fetch _ _ = pure (Right [])
    fetchOptions :: Integer -> Maybe Integer -> Plugin.EvidenceSnapshot Item -> Acquisition Item (Either Plugin.FetchError [Plugin.EvidenceChange Item])
    fetchOptions _ _ _ = pure (Right [])
    fetchState :: Integer -> Plugin.FetchContext Integer -> Plugin.EvidenceSnapshot Item
      -> Acquisition Item (Either Plugin.FetchError (Plugin.FetchResult Item Integer Integer))
    fetchState config (Plugin.FetchContext _ prior) _ = pure (Right (Plugin.FetchResult [] (config + maybe 0 id prior) 5))
    fetchStateOptions :: Integer -> Maybe Integer -> Plugin.FetchContext Integer -> Plugin.EvidenceSnapshot Item
      -> Acquisition Item (Either Plugin.FetchError (Plugin.FetchResult Item Integer Integer))
    fetchStateOptions config options = fetchState (config + maybe 0 id options)

checkAcquisition :: (FilePath,[String]) -> IO ()
checkAcquisition executable = do
  descriptionValue <- invoke executable (toJSON G.Describe)
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode descriptionValue)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  unless (length [() | G.AcquisitionEntry{} <- description.entries] == 4) (fail "Missing acquisition shapes")
  case [entry | entry@G.AcquisitionEntry{} <- description.entries] of
    selected@(G.AcquisitionEntry _ connector (G.StatelessContracts _ _ payload)) : _ -> do
      unless (isLeft (Host.checkGuest description { G.entries = selected { G.entryName = "duplicate" } : description.entries }))
        (fail "Duplicate acquisition role accepted")
      -- The replacement contract is valid by itself, but wrong for this config.
      let mismatch = G.ConfigurationEntry "mismatch" connector payload
          withoutConfig = [entry | entry <- description.entries, case entry of
            G.ConfigurationEntry _ actual _ -> actual /= connector
            _ -> True]
      unless (isLeft (Host.checkGuest description { G.entries = mismatch : withoutConfig }))
        (fail "Inconsistent connector configuration contracts accepted")
    _ -> fail "Missing stateless acquisition fixture"
  let input = G.AcquisitionInvocation (String "10") Nothing Nothing "snapshot-1" 1
      context = G.AcquisitionContext "2026-11-06T12:00:00Z" (Just (String "7"))
      completed result = object ["tag" .= ("Completed" :: String),"result" .= object ["tag" .= ("Right" :: String),"value" .= result]]
      state position = object ["changes" .= ([] :: [Value]),"position" .= (position :: String),"report" .= ("5" :: String)]
  forM_ [("$acquisition.local-file.Files",input,Array mempty),
    ("$acquisition.local-file.Options",input { G.acquisitionOptions = Just (String "3") },Array mempty),
    ("$acquisition.local-file.State",input { G.acquisitionContext = Just context },state "17"),
    ("$acquisition.local-file.StateOptions",input { G.acquisitionOptions = Just (String "3"),G.acquisitionContext = Just context },state "20")] $
      \(name,arguments,expected) -> do
        result <- invoke executable (toJSON (G.Invoke name (toJSON arguments)))
        unless (result == completed expected) (fail ("Wrong normalized acquisition result: " ++ show result))
  forM_ [("$acquisition.local-file.Files",input { G.acquisitionOptions = Just (String "3") }),
    ("$acquisition.local-file.Files",input { G.acquisitionContext = Just context }),
    ("$acquisition.local-file.State",input),
    ("$acquisition.local-file.Files",input { G.acquisitionConfig = String "bad" }),
    ("$acquisition.local-file.Options",input { G.acquisitionOptions = Just (String "bad") }),
    ("$acquisition.local-file.State",input { G.acquisitionContext = Just (G.AcquisitionContext "now" (Just (String "bad"))) }),
    ("$acquisition.local-file.Files",input { G.acquisitionConcurrency = 0 }),
    ("$acquisition.local-file.Files",input { G.acquisitionConcurrency = 9 })] $ \(name,arguments) -> do
      (status,_,_) <- call executable (toJSON (G.Invoke name (toJSON arguments)))
      unless (status /= ExitSuccess) (fail "Malformed or inapplicable acquisition arguments accepted")
  putStrLn "All four acquisition shapes normalize and reject invalid arguments."

pluginGuest :: IO ()
pluginGuest = runGuest []
  [configurationEntry "$configuration.local-file.Files" (G.ConnectorIdentity "local-file" "Files") [] validate,
   loginEntry "$login.local-file.Files" (G.ConnectorIdentity "local-file" "Files") [] login,
   configurationEntry "$configuration.local-file.Writer" (G.ConnectorIdentity "local-file" "Writer") [] validate,
   sinkEntry "$sink.local-file.Writer" (G.ConnectorIdentity "local-file" "Writer") [] publish,
   sinkDefaultsEntry "$sinkDefaults.local-file.Writer" (G.ConnectorIdentity "local-file" "Writer") [] (3 :: Integer)]
  where
    validate :: Integer -> ValidationReport
    validate _ = ValidationReport []
    login :: Integer -> PluginLogin (Either LoginError ())
    login _ = pure (Right ())
    publish :: Integer -> Integer -> Integer -> Sink (Either SinkError Integer)
    publish config options input = pure (Right (config + options + input))

checkPlugin :: (FilePath,[String]) -> IO ()
checkPlugin executable = do
  descriptionValue <- invoke executable (toJSON G.Describe)
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode descriptionValue)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  let completed result = object ["tag" .= ("Completed" :: String),"result" .= object ["tag" .= ("Right" :: String),"value" .= result]]
  forM_ [("$configuration.local-file.Files",String "10",Array mempty),
    ("$login.local-file.Files",toJSON (G.LoginInvocation (String "10")),completed (object [])),
    ("$sinkDefaults.local-file.Writer",object [],String "3"),
    ("$sink.local-file.Writer",toJSON (G.SinkInvocation (String "10") (String "3") (String "7")),completed (String "20"))] $
      \(name,arguments,expected) -> do
        result <- invoke executable (toJSON (G.Invoke name arguments))
        unless (result == expected) (fail ("Wrong plugin result: " ++ show result))
  forM_ [("$configuration.local-file.Files",String "bad"),
    ("$login.local-file.Files",object []),
    ("$login.local-file.Files",toJSON (G.LoginInvocation (String "bad"))),
    ("$sinkDefaults.local-file.Writer",String "not unit"),
    ("$sink.local-file.Writer",object []),
    ("$sink.local-file.Writer",toJSON (G.SinkInvocation (String "10") (String "bad") (String "7")))] $
      \(name,arguments) -> do
        (status,_,_) <- call executable (toJSON (G.Invoke name arguments))
        unless (status /= ExitSuccess) (fail "Malformed plugin invocation accepted")
  putStrLn "Configuration, login, sink defaults and publication entries pass."
