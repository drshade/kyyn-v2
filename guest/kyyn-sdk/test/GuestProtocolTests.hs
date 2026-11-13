-- A real subprocess describes and invokes the same compiled fixture through the
-- host frame codec, including captured-read callbacks and response ID rejection.
-- --recipe-built also checks finite recursive rendering and structural refusals.
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
import qualified Agentic.Contract as Agentic
import qualified Agentic.Schema as Agentic
import qualified Agentic.Value as Agentic
import Kyyn.Runtime.AgenticContract (fromWireCodec)
import qualified Kyyn.Runtime.Json as Wire
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
    ["--frozen-api-built",path] -> checkFrozenApi (path,[])
    ["--root-api-built",path] -> checkRootApi (path,[])
    ["--recipe-built",path] -> checkRecipe (path,[])
    ["--tool-built",path] -> checkTool (path,[])
    ["--captured-built",path] -> checkCaptured (path,[]) >> checkAcquisition (path,[]) >> checkPlugin (path,[])
    ["--built",path] -> check (path,[])
    ["--schema-built",path] -> checkSchema (path,[])
    ["--api-tools-built",path] -> checkToolApi (path,[])
    ["--api-built",path] -> checkApi False (path,[])
    ["--api-bindings-built",path] -> checkApi True (path,[])
    [] -> do
      checkModelBridge
      path <- getExecutablePath
      check (path,["--guest"])
      checkCaptured (path,["--captured-guest"])
      checkAcquisition (path,["--acquisition-guest"])
      checkPlugin (path,["--plugin-guest"])
    _ -> fail "Expected --guest or --built EXECUTABLE"

checkModelBridge :: IO ()
checkModelBridge = do
  let Agentic.Codec _ _ decode = fromWireCodec (Agentic.schemaOf (Agentic.SObject []))
        (Wire.Codec (const (object [])) (const (Right ())))
  forM_ [Agentic.Object [("a",Agentic.Bool True),("a",Agentic.Bool False)],
    Agentic.Array [Agentic.Object [("a",Agentic.Bool True),("a",Agentic.Bool False)]]] $ \value ->
      unless (decode value == Left "duplicate object keys") (fail "Model duplicate was not a typed refusal")
  forM_ [0/0,1/0, -1/0] $ \value ->
    unless (decode (Agentic.Number value) == Left "Expected finite model number")
      (fail "Nonfinite model number was not a typed refusal")
  putStrLn "Model bridge refuses duplicate objects and nonfinite numbers without exceptions."

-- Broken proposal data and an unfinished transformation must not be read/run by
-- discovery. Its compiler-owned facade has the real exports but no invocation.
checkFrozenApi :: (FilePath,[String]) -> IO ()
checkFrozenApi executable = do
  value <- invoke executable (toJSON G.Describe)
  described <- right (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest described)
  let exports = [e | m <- described.modules, m.moduleName == "KyynFrozenProposal", e <- m.moduleExports]
  unless (all (`elem` map G.exportName exports) ["frozen","proposal"])
    (fail "Frozen proposal facade exports missing")
  unless (any (\entry -> entry.exportName == "frozen" && "RecipeEvolution" `Text.isInfixOf` entry.exportSignature) exports)
    (fail "Frozen proposal signature missing")
  unless (all (\entry -> case entry of G.ContractEntry {} -> True; _ -> False) described.entries)
    (fail "Discovery artifact contains runnable entries")
  (status,_,_) <- call executable (toJSON (G.Invoke "frozen" (object [])))
  unless (status /= ExitSuccess) (fail "Discovery facade was invocable")
  putStrLn "Frozen proposal discovery exposes its typed facade without reading payloads or invoking it."

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

checkToolApi :: (FilePath,[String]) -> IO ()
checkToolApi executable = do
  value <- invoke executable (toJSON G.Describe)
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  unless (null description.entries) (fail "Tool discovery produced invocable entries")
  let symbols = [(m.moduleName,e.exportName) | m <- description.modules, e <- m.moduleExports]
  unless (all (`elem` symbols) [("Tools","count"),("Kyyn.Connectors","Tool"),("Kyyn.Connectors","files"),
    ("Kyyn.Agentic","interpret"),("Kyyn.Plugins.P_local_file.Files","count"),
    ("Kyyn.Plugins.P_local_file.Files.Evidence","readEvidence")])
    (fail "Generated tool API is incomplete")
  unless (all ((/= "Main") . G.moduleName) description.modules) (fail "Tool API included unrelated Root")
  putStrLn "Generated tool APIs inspect successfully with unfinished Root and manifest."

checkSchema :: (FilePath,[String]) -> IO ()
checkSchema executable = do
  value <- invoke executable (object ["operation" .= ("describe" :: String)])
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  case description.entries of
    [G.ContractEntry "root" selected] ->
      unless (selected.loadedSources == ["src/LanguageDefaults.hs","src/Main.hs"]) (fail "Wrong schema-only source closure")
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
  _ <- right (Host.checkGuest description)
  unless (isLeft (Host.checkGuest description { G.entries = description.entries ++ description.entries })) (fail "Duplicate entries accepted")
  let field signature = G.ExportDescription "value" signature "Records.value" Nothing G.ExportValue
      exports = G.ModuleDescription "Records" "" Nothing [] [field "value :: First -> Integer",field "value :: Second -> Integer"]
  _ <- right (Host.checkGuest description { G.modules = [exports] })
  unless (isLeft (Host.checkGuest description { G.modules = [exports { G.moduleExports = exports.moduleExports ++ exports.moduleExports }] }))
    (fail "Duplicate exported selectors accepted")
  let changeContracts change = description { G.entries = map (fmap change) description.entries }
  unless (isLeft (Host.checkGuest (changeContracts (\selected -> selected { G.loadedSources = ["../outside.hs"] }))))
    (fail "Source traversal accepted")
  unless (concatMap G.entryNames description.entries == ["validate","total"]) (fail "Wrong registered entries")
  selectedRoot <- case [root | G.ValidatorEntry _ root <- description.entries] of
    [root] -> pure root
    _ -> fail "Missing validator contract"
  let malformed entry = object ["entries" .= [entry],"modules" .= ([] :: [Value])]
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
  forM_ ["{\"operation\":\"describe\",\"operation\":\"describe\"}",
    "{\"operation\":\"describe\",\"\\u006fperation\":\"describe\"}",
    "{\"operation\":\"invoke\",\"entry\":\"validate\",\"argument\":{\"items\":[{\"id\":\"a\",\"value\":{\"amount\":\"12.34\",\"amount\":\"12.34\"}}]}}"] $ \metadata -> do
      (status,_,_) <- callRaw executable metadata
      unless (status /= ExitSuccess) (fail "Duplicate-key invocation accepted")
  putStrLn "Compiled guest describe/invoke and rejection checks passed."

call :: (FilePath,[String]) -> Value -> IO (ExitCode,Lazy.ByteString,Lazy.ByteString)
call executable value = callRaw executable (Lazy.toStrict (encode value))

callRaw :: (FilePath,[String]) -> Bytes.ByteString -> IO (ExitCode,Lazy.ByteString,Lazy.ByteString)
callRaw (executable,arguments) metadata = Process.readProcess (Process.setStdin (Process.byteStringInput
  (Lazy.fromStrict (Bytes.concat (Frame.encodeFrame (Frame.jsonFrame metadata)))))
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
capturedGuest = runGuest [] [sourceConnectorEntry (G.ConnectorIdentity "local-file" "Files")
  (configurationEntry "$configuration.local-file.Files" [] validateConfig)
  (acquisitionEntry "$acquisition.local-file.Files" [] emptyFetch) Nothing
  [capturedReadEntry @() @Item @Integer "local-file.Files.count"
  (G.CapturedMethodIdentity "local-file" "Files" "count" "Count captured files") []
  (\() snapshot -> fmap (fmap (toInteger . length)) (Plugin.listEvidenceIds snapshot))]]

validateConfig :: Integer -> ValidationReport
validateConfig _ = ValidationReport []
emptyFetch :: Integer -> Plugin.EvidenceSnapshot Item -> Acquisition Item (Either Plugin.FetchError [Plugin.EvidenceChange Item])
emptyFetch _ _ = pure (Right [])

checkCaptured :: (FilePath,[String]) -> IO ()
checkCaptured executable@(path,args) = do
  descriptionValue <- invoke executable (object ["operation" .= ("describe" :: String)])
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode descriptionValue)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  let methods = [method | G.ConnectorEntry _ (G.SourceEntries _ _ _ captured) <- description.entries, method <- captured]
  case methods of
    [G.CapturedEntry "count" _ (G.Invocation "local-file.Files.count" _)] -> pure ()
    _ -> fail "Missing captured read entry"
  let duplicate entry = case entry of
        G.ConnectorEntry ident (G.SourceEntries config acquire login captured) ->
          G.ConnectorEntry ident (G.SourceEntries config acquire login (captured ++ captured))
        other -> other
  unless (isLeft (Host.checkGuest description { G.entries = map duplicate description.entries }))
    (fail "Duplicate captured method accepted")
  forM_ ["", "bad/plugin"] $ \bad -> do
    let invalid entry = case entry of
          G.ConnectorEntry ident selected -> G.ConnectorEntry ident { G.connectorPlugin = bad } selected
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
  forM_ [G.RunRecipe (object []) (object []) (object []),G.RenderRecipe G.Tree,G.RenderRecipe G.Dot,G.RenderRecipe G.Mermaid] $ \request -> do
    decoded <- right (eitherDecodeStrict' (Lazy.toStrict (encode request)))
    unless (decoded == request) (fail "Shared recipe invocation changed")
  forM_ [object [],object ["operation" .= String "run","root" .= object [],"input" .= object []],
      object ["operation" .= String "render","format" .= String "unknown"],
      object ["operation" .= String "render","format" .= String "tree","extra" .= True]] $ \value ->
    unless (isLeft (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.RecipeInvocation))
      (fail "Malformed shared recipe invocation accepted")
  let query = G.QueryInvocation (object []) (object [])
  decodedQuery <- right (eitherDecodeStrict' (Lazy.toStrict (encode query)))
  unless (decodedQuery == query) (fail "Shared query invocation changed")
  forM_ [object ["root" .= object []],object ["root" .= object [],"arguments" .= object [],"extra" .= True]] $ \value ->
    unless (isLeft (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.QueryInvocation))
      (fail "Malformed shared query invocation accepted")
  forM_ [object ["arguments" .= object []],
    object ["arguments" .= object [],"snapshot" .= Null],
    object ["arguments" .= object [],"snapshot" .= ("id" :: String),"extra" .= True]] $ \value ->
      unless (isLeft (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.CapturedInvocation))
        (fail "Malformed shared captured invocation accepted")

acquisitionGuest :: IO ()
acquisitionGuest = runGuest []
  [source "Files" (acquisitionEntry "$acquisition.local-file.Files" [] fetch),
   source "Options" (acquisitionEntry "$acquisition.local-file.Options" [] fetchOptions),
   source "State" (acquisitionEntry "$acquisition.local-file.State" [] fetchState),
   source "StateOptions" (acquisitionEntry "$acquisition.local-file.StateOptions" [] fetchStateOptions)]
  where
    source name acquire = sourceConnectorEntry (G.ConnectorIdentity "local-file" name)
      (configurationEntry ("$configuration.local-file." <> name) [] validateConfig) acquire Nothing []
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
  unless (length [() | G.ConnectorEntry _ G.SourceEntries{} <- description.entries] == 4) (fail "Missing acquisition shapes")
  case [entry | entry@G.ConnectorEntry{} <- description.entries] of
    selected@(G.ConnectorEntry ident (G.SourceEntries config acquire login methods)) : _ -> do
      unless (isLeft (Host.checkGuest description { G.entries = selected : description.entries }))
        (fail "Duplicate connector accepted")
      case toJSON selected of
        Object outer -> case Keys.lookup "entries" outer of
          Just (Object roles) -> forM_ [Keys.delete "configure" roles,Keys.delete "acquire" roles,
              Keys.insert "publish" (object []) roles,Keys.insert "login" Null roles] $ \malformed -> do
            let encoded = encode (Object (Keys.insert "entries" (Object malformed) outer))
            unless (isLeft (eitherDecodeStrict' (Lazy.toStrict encoded) :: Either String G.EntryDescription))
              (fail "Incomplete or mixed connector roles accepted")
          _ -> fail "Missing connector roles"
        _ -> fail "Connector is not an object"
      let payload = case acquire.invocationContract of
            G.StatelessContracts _ _ p -> p
            G.StatefulContracts _ _ p _ _ -> p
          mismatch = G.ConnectorEntry ident (G.SourceEntries config { G.invocationContract = payload } acquire login methods)
      unless (isLeft (Host.checkGuest description { G.entries = mismatch : drop 1 description.entries }))
        (fail "Inconsistent connector configuration contracts accepted")
    _ -> fail "Missing acquisition fixture"
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
  [sourceConnectorEntry (G.ConnectorIdentity "local-file" "Files")
    (configurationEntry "$configuration.local-file.Files" [] validate)
    (acquisitionEntry "$acquisition.local-file.Files" [] emptyFetch)
    (Just (loginEntry "$login.local-file.Files" [] login)) [],
   sinkConnectorEntry (G.ConnectorIdentity "local-file" "Writer")
    (configurationEntry "$configuration.local-file.Writer" [] validate)
    (sinkEntry "$sink.local-file.Writer" [] publish)
    (sinkDefaultsEntry "$sinkDefaults.local-file.Writer" [] (3 :: Integer))]
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
    ("$sinkDefaults.local-file.Writer",toJSON G.SinkDefaultsInvocation,String "3"),
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

checkTool :: (FilePath,[String]) -> IO ()
checkTool executable@(path,args) = do
  descriptionValue <- invoke executable (toJSON G.Describe)
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode descriptionValue)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  let selected = [(name,entry) | G.ToolEntry entry name _ _ <- description.entries]
  unless (map fst selected == ["count","listCount"]) (fail "Missing composed tools")
  forM_ selected $ \(name,entry) -> do
    let fields = ["plugin" .= ("local-file" :: String),"connectorType" .= ("Files" :: String),"instance" .= ("reader" :: String)]
        (capability,method,arguments,responseValue) = if name == "count"
          then ("plugin","read",object (fields ++ ["method" .= ("count" :: String),"input" .= object []]),String "2")
          else ("evidence","list",object fields,toJSON (["one","two"] :: [String]))
        response = object ["tag" .= ("HostResponse" :: String),"id" .= ("1" :: String),
          "result" .= object ["tag" .= ("Right" :: String),"value" .= responseValue]]
        invocation = toJSON (G.Invoke entry (object []))
        framed value = Bytes.concat (Frame.encodeFrame (Frame.jsonFrame (Lazy.toStrict (encode value))))
    (status,output,errors) <- Process.readProcess (Process.setStdin (Process.byteStringInput
      (Lazy.fromStrict (framed invocation <> framed response))) (Process.proc path args))
    unless (status == ExitSuccess) (fail (show errors))
    (Frame.Frame request body,rest) <- right (runIdentity (Frame.readFrame (pure Nothing) (Lazy.toStrict output)))
    actual <- right (eitherDecodeStrict' request)
    unless (Bytes.null body && actual == object ["tag" .= ("HostRequest" :: String),"id" .= ("1" :: String),
      "capability" .= (capability :: String),"method" .= (method :: String),"arguments" .= arguments])
      (fail ("Composed tool emitted the wrong callback: " ++ show actual))
    (Frame.Frame completed completedBody,remaining) <- right (runIdentity (Frame.readFrame (pure Nothing) rest))
    result <- right (eitherDecodeStrict' completed)
    unless (Bytes.null completedBody && Bytes.null remaining && result == object
      ["tag" .= ("Completed" :: String),"result" .= object ["tag" .= ("Right" :: String),"value" .= ("2" :: String)]])
      (fail "Composed tool returned the wrong result")
    (bad,_,_) <- call executable (toJSON (G.Invoke entry (String "invalid")))
    unless (bad /= ExitSuccess) (fail "Invalid tool input accepted")
  putStrLn "Root-built tools invoke captured methods and evidence through the generated Calls algebra."

-- The fixture's state is private and its flow calls a generated connector proxy.
checkRecipe :: (FilePath,[String]) -> IO ()
checkRecipe executable@(path,args) = do
  described <- invoke executable (toJSON G.Describe)
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode described)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  entry <- case [name | G.RecipeEntry name "Flows.review" _ <- description.entries] of
    [name] -> pure name
    _ -> fail "Missing recipe description"
  unless (all (`elem` [name | G.ContractEntry name _ <- description.entries]) ["$state.()","$state.Progress.State"])
    (fail "Open recipe state contracts missing")
  forM_ [G.Tree,G.Dot,G.Mermaid] $ \format -> do
    rendered <- invoke executable (toJSON (G.Invoke entry (toJSON (G.RenderRecipe format))))
    case rendered of
      String value | not (Text.null value) -> pure ()
      _ -> fail "Flow rendering did not return text"
  forM_ [G.Tree,G.Dot,G.Mermaid] $ \format -> do
    rendered <- invoke executable (toJSON (G.Invoke "$recipe.Flows.recursive" (toJSON (G.RenderRecipe format))))
    case rendered of
      String value | "again" `Text.isInfixOf` value -> pure ()
      _ -> fail "Recursive flow description lost its tool definition"
    (status,output,errors) <- call executable
      (toJSON (G.Invoke "$recipe.Flows.invalidRecursive" (toJSON (G.RenderRecipe format))))
    unless (status /= ExitSuccess && "InvalidRecursion" `Text.isInfixOf` Text.pack (show errors))
      (fail ("Invalid recursive description did not report its structural error: " ++ show (status,output,errors)))
  let input = G.RunRecipe (object ["items" .= ([] :: [Value])]) (object []) (object ["runs" .= String "4"])
      invocation = toJSON (G.Invoke entry (toJSON input))
      response = object ["tag" .= String "HostResponse","id" .= String "1",
        "result" .= object ["tag" .= String "Right","value" .= String "2"]]
      framed value = Bytes.concat (Frame.encodeFrame (Frame.jsonFrame (Lazy.toStrict (encode value))))
  (status,output,errors) <- Process.readProcess (Process.setStdin (Process.byteStringInput
    (Lazy.fromStrict (framed invocation <> framed response))) (Process.proc path args))
  unless (status == ExitSuccess) (fail (show errors))
  (Frame.Frame request body,rest) <- right (runIdentity (Frame.readFrame (pure Nothing) (Lazy.toStrict output)))
  callback <- right (eitherDecodeStrict' request)
  unless (Bytes.null body && callback == object ["tag" .= String "HostRequest","id" .= String "1",
      "capability" .= String "plugin","method" .= String "read","arguments" .= object
      ["plugin" .= String "local-file","connectorType" .= String "Files","instance" .= String "reader",
       "method" .= String "count","input" .= object []]]) (fail ("Wrong recipe callback: " ++ show callback))
  (Frame.Frame completed completedBody,remaining) <- right (runIdentity (Frame.readFrame (pure Nothing) rest))
  result <- right (eitherDecodeStrict' completed)
  let operation = object ["tag" .= String "Edit_items","value" .= object ["tag" .= String "Append","value" .= object
        ["id" .= String "recipe-item","value" .= object ["amount" .= String "1"]]]]
      proposal = object ["steps" .= [object ["rationale" .= object ["explanation" .= String "One recipe step","evidence" .= ([] :: [Value])],
        "edits" .= [operation]]],"state" .= object ["runs" .= String "7"]]
  unless (Bytes.null completedBody && Bytes.null remaining && result == object ["tag" .= String "Completed",
    "result" .= object ["tag" .= String "Right","value" .= proposal]]) (fail ("Wrong recipe proposal: " ++ show result))
  forM_ [object [],toJSON (G.RunRecipe (object []) (object []) (object ["runs" .= String "4"])),
      toJSON (G.RunRecipe (object ["items" .= ([] :: [Value])]) (object []) (object ["runs" .= String "bad"]))] $ \malformed -> do
    (bad,_,_) <- call executable (toJSON (G.Invoke entry malformed))
    unless (bad /= ExitSuccess) (fail "Malformed recipe invocation accepted")
  putStrLn "Recipe guest describes private state, renders flows, exchanges connector callbacks and returns typed fact edits."

checkRootApi :: (FilePath,[String]) -> IO ()
checkRootApi executable = do
  value <- invoke executable (toJSON G.Describe)
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  unless (null description.entries && all (\name -> any (\entry -> entry.moduleName == name && not (null entry.moduleExports)) description.modules)
    ["Kyyn.Workspace.Evolution","Kyyn.Workspace.FactEdits","Kyyn.Connectors","Kyyn.Agentic","Kyyn.Plugins.P_local_file.Files"])
    (fail "Root catalogue is missing generated API exports")
  unless (any (\entry -> entry.moduleName == "Unfinished" && null entry.moduleExports && entry.moduleSource == "src/Unfinished.hs") description.modules)
    (fail "Root inventory compiled unfinished authored source or lost its name")
  putStrLn "Root API inventories authored modules and describes generated bindings without compiling unfinished bodies."
