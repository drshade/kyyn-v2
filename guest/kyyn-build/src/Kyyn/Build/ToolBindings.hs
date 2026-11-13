{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Build.ToolBindings (writeToolBindings) where

import Control.Monad (forM, forM_, unless)
import Data.List (nub, intercalate)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>), takeDirectory)
import Kyyn.Build.Manifest
import Kyyn.Build.Plugins
import qualified Kyyn.Types.Plugin as P

writeToolBindings :: FilePath -> [FilePath] -> [RegisteredPlugin] -> IO ()
writeToolBindings generated roots plugins = do
  let connectors = zip [0 :: Int ..]
        [(plugin,connector,fetch,captured) | RegisteredPlugin plugin declarations <- plugins,
          connector@P.SourceConnector{P.fetch = fetch, P.methods = captured} <- declarations]
      methods = [(index,plugin,connector,method) | (index,(plugin,connector,_,captured)) <- connectors, method <- captured]
      references = [fetch | (_index,(_plugin,_connector,fetch,_)) <- connectors] ++
        [method.implementation | (_index,_plugin,_connector,method) <- methods]
  modules <- traverse (fmap (Text.unpack . referenceModule) . either fail pure . qualifiedReference False) references
  write "KyynToolCalls" (unlines
    (["{-# LANGUAGE TemplateHaskell #-}",
      "module KyynToolCalls where", "import Kyyn.Build.Captured", "import Language.Haskell.TH (mkName)"] ++
      map ("import qualified " ++) (nub modules) ++
      ["$(toolCalls (mkName \"Calls\")",
       "  [" ++ intercalate "," ["ConnectorBinding (mkName " ++ show (tag index) ++ ") '" ++ Text.unpack fetch ++
         " " ++ show (plugin.sourceRoot ++ ": " ++ Text.unpack connector.name) | (index,(plugin,connector,fetch,_)) <- connectors] ++ "]",
       "  [" ++ intercalate "," ["CapturedBinding (mkName " ++ show (call index method) ++ ") (mkName " ++ show (proxy index method) ++
         ") (mkName " ++ show (tag index) ++ ") '" ++ Text.unpack method.implementation ++ " " ++
         show (plugin.sourceRoot ++ ": " ++ Text.unpack connector.name) | (index,plugin,connector,method) <- methods] ++ "])"]))
  forM_ connectors $ \(index,(plugin,connector,_,captured)) -> do
    let name = proxyModule plugin.pluginName connector.name
    write name (unlines
      (["{-# LANGUAGE NoMonomorphismRestriction #-}","module " ++ name ++ " where",
        "import Kyyn.Types.Plugin (ConnectorInstance)","import qualified KyynToolCalls as Calls",
        "type Instance = ConnectorInstance Calls." ++ tag index] ++
       [Text.unpack method.methodName ++ " = Calls." ++ proxy index method | method <- captured]))
    write (name ++ ".Evidence") (unlines
      ["{-# LANGUAGE NoMonomorphismRestriction #-}","module " ++ name ++ ".Evidence where",
       "import qualified KyynToolCalls as Calls",
       "listEvidenceIds = Calls.listEvidence_" ++ tag index,
       "readEvidence = Calls.readEvidence_" ++ tag index])
  configured <- fmap concat $ forM plugins $ \(RegisteredPlugin plugin declarations) -> do
    let path = "plugins/config/" ++ Text.unpack plugin.pluginName ++ ".dhall"
    exists <- doesFileExist path
    instances <- if exists then Text.readFile path >>= either (fail . ((path ++ ": ") ++)) pure . parseInstances else pure []
    forM instances $ \selected -> do
      unless (selected.instanceConnector `elem` map (\connector -> connector.name) declarations)
        (fail (path ++ ": unknown configured connector " ++ Text.unpack selected.instanceConnector))
      let source = selected.instanceConnector `elem` [connector.name | connector@P.SourceConnector{} <- declarations]
      pure (plugin,selected,source)
  let bindings = [selected.instanceBinding | (_,selected,_) <- configured]
  unless (length bindings == length (nub bindings)) (fail "Connector bindings must be unique across the KB")
  write "Kyyn.Connectors" (unlines
    (["module Kyyn.Connectors where",
      "import Kyyn.Types.Program (Program)","import Kyyn.Types.Plugin (ConnectorInstance(..))",
      "import qualified KyynToolCalls as Calls", "type Tool = Program Calls.Calls"] ++
     concat [[Text.unpack selected.instanceBinding ++ " :: ConnectorInstance Calls." ++ tag index,
       Text.unpack selected.instanceBinding ++ " = ConnectorInstance " ++ show selected.instanceName] |
       (plugin,selected,True) <- configured,
       (index,(actual,connector,_,_)) <- connectors,
       actual.pluginName == plugin.pluginName, connector.name == selected.instanceConnector]))
  write "Kyyn.Agentic" (unlines
    ["module Kyyn.Agentic (Step, Flow, interpret, liftTool) where",
     "import KyynFlowRuntime (Step, Flow, interpret, liftTool)"])
  write "KyynFlowRuntime" agenticModule
  write "KyynGuestDispatch" (unlines
    (["module KyynGuestDispatch (dispatch) where",
      "import qualified KyynToolCalls as Calls", "import Kyyn.Types.Plugin (ConnectorInstance(..))",
      "import Kyyn.Types.Guest (ConnectorIdentity(..), CapturedMethodIdentity(..))",
      "import Kyyn.Runtime.ToolEntry", "import Kyyn.Runtime.Transport (Transport)",
      "import Kyyn.Runtime.Flow (exchangeObservation)",
      "import Kyyn.Runtime.Judgement (exchangeJudgement)", "import Kyyn.Runtime.Model (exchangeModel)",
      "dispatch :: Transport -> Integer -> Calls.Calls a -> IO a",
      "dispatch transport requestId (Calls.JudgementCall request) = exchangeJudgement transport requestId request",
      "dispatch transport requestId (Calls.ModelCall request) = exchangeModel transport requestId request",
      "dispatch transport requestId (Calls.ObserveFlow summary) = exchangeObservation transport requestId summary"] ++
     concat [["dispatch transport requestId (Calls.ListEvidence_" ++ tag index ++ " (ConnectorInstance name)) =",
       "  exchangeEvidenceList transport requestId " ++ identity plugin connector ++ " name",
       "dispatch transport requestId (Calls.ReadEvidence_" ++ tag index ++ " (ConnectorInstance name) key) =",
       "  exchangeEvidenceRead transport requestId " ++ identity plugin connector ++ " name key"] |
       (index,(plugin,connector,_,_)) <- connectors] ++
     concat [["dispatch transport requestId (Calls." ++ call index method ++ " (ConnectorInstance name) arguments) =",
       "  exchangeCaptured transport requestId (CapturedMethodIdentity " ++ unwords (map show
         [plugin.pluginName,connector.name,method.methodName,method.methodDescription]) ++ ") name arguments"] |
       (index,plugin,connector,method) <- methods]))
  where
    write name contents = do
      let relative = map (\c -> if c == '.' then '/' else c) name
          path = generated </> relative ++ ".hs"
      occupied <- or <$> traverse doesFileExist [root </> relative ++ ext | root <- roots, ext <- [".hs",".lhs"]]
      unless (not occupied) (fail ("Authored source collides with generated module " ++ name))
      createDirectoryIfMissing True (takeDirectory path)
      writeFile path contents
    tag index = "Connector" ++ show index
    call index method = "Call" ++ show index ++ "_" ++ Text.unpack method.methodName
    proxy index method = "captured" ++ show index ++ "_" ++ Text.unpack method.methodName
    identity plugin connector = "(ConnectorIdentity " ++ show plugin.pluginName ++ " " ++ show connector.name ++ ")"

proxyModule :: Text -> Text -> String
proxyModule plugin connector = "Kyyn.Plugins.P_" ++ map (\c -> if c == '-' then '_' else c) (Text.unpack plugin) ++ "." ++ Text.unpack connector

agenticModule :: String
agenticModule = unlines
  ["module KyynFlowRuntime (Step, Flow, interpret, interpretObserved, liftTool) where",
   "import qualified Agentic as A", "import qualified Agentic.Runtime as A",
   "import Agentic.Runtime (Runtime(..))",
   "import Kyyn.Runtime.Flow (programScope)",
   "import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)",
   "import Control.Monad.Trans.Class (lift)",
   "import Kyyn.Types.Plugin (FetchError(..))", "import Kyyn.Types.Program (request)", "import qualified Data.Text as Text",
   "import Kyyn.Connectors (Tool)", "import qualified KyynToolCalls as Calls",
   "type Flow input output = A.Agentic Step input output", "type Step = ExceptT FetchError Tool",
   "interpret :: Flow input output -> input -> Tool (Either FetchError output)",
   "interpret flow input = runExceptT (A.interpret runtime flow input)",
   "interpretObserved :: Flow input output -> input -> Tool (Either FetchError output)",
   "interpretObserved flow input = runExceptT (A.interpret runtime",
   "  { observe = lift . request . Calls.ObserveFlow . A.summarise } flow input)",
   "runtime :: A.Runtime Step",
   "runtime = (A.runtimeWith (throwE . FetchError . Text.pack . show))",
   "  { scope = A.exceptTScope programScope",
   "  , systemOne = A.SystemOne $ \\question ->",
   "      lift (request (Calls.JudgementCall question)) >>= either (throwE . FetchError . Text.pack) pure",
   "  , systemTwo = A.SystemTwo $ \\conversation ->",
   "      lift (request (Calls.ModelCall conversation)) >>= either (throwE . FetchError . Text.pack) pure }",
   "liftTool :: Tool a -> Step a", "liftTool = lift"]
