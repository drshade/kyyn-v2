-- Pure CLI parsing/routing, defaults, shared options, help and invalid arguments.
-- Does not execute KB operations or guest code.

module Main (main) where

import Control.Monad (forM_, unless)
import Data.List (isInfixOf)
import Kyyn.Domain.Evolution (EvolutionName(..), EvolutionFilter(..), evolutionId)
import Kyyn.Domain.Git (gitRevision, gitUrl)
import Kyyn.Domain.Tap (tapName)
import Kyyn.Domain.Plugin (pluginName, connectorName, methodName)
import Kyyn.Domain.Evidence (FetchId(..))
import Kyyn.Domain.Curation (RecipeId(..))
import Kyyn.Domain.Recipe (DescriptionFormat(..))
import Kyyn.Domain.Secret (secretName)
import Kyyn.Surfaces.Cli
import Options.Applicative (ParserResult(..), renderFailure)
import System.Exit (ExitCode(..))

main :: IO ()
main = do
  let selected = Selection "." Nothing Nothing
      identity = either error id (evolutionId "abc123")
      revision = either error id (gitRevision (replicate 40 'a'))
      localFile = either error id (pluginName "local-file")
      sales = either error id (connectorName "sales")
      content = either error id (methodName "content")
      assert label condition = unless condition (fail label)
      succeeds args expected = case parseArguments args of
        Success actual -> assert ("Wrong parse: " ++ show args ++ ": " ++ show actual) (actual == expected)
        _ -> fail ("Parse failed: " ++ show args)
      refuses args = case parseArguments args of
        Failure failure -> let (_,status) = renderFailure failure "kyyn"
                           in assert ("Expected usage exit 2: " ++ show args) (status == ExitFailure 2)
        _ -> fail ("Unexpectedly accepted: " ++ show args)
  succeeds ["root","show"] (Invocation selected Human (Root ShowRoot))
  succeeds ["root","schema","list"] (Invocation selected Human (Root (RootSchema (ListSchemas Nothing))))
  succeeds ["root","schema","show","Todos.Root","--evolution","abc123"]
    (Invocation selected Human (Root (RootSchema (ShowSchema "Todos.Root" (Just identity)))))
  succeeds ["root","collection","list","--evolution","abc123"]
    (Invocation selected Human (Root (RootCollection (ListCollections (Just identity)))))
  succeeds ["root","collection","show","todos"]
    (Invocation selected Human (Root (RootCollection (ShowCollection "todos" Nothing))))
  succeeds ["root","fact","list","todos"] (Invocation selected Human (Root (RootFact (ListFacts "todos"))))
  succeeds ["root","fact","show","todos","some/♥ id"]
    (Invocation selected Human (Root (RootFact (ShowFact "todos" "some/♥ id"))))
  forM_ [["root","schema","show"], ["root","collection","show"], ["root","fact","list"],
    ["root","fact","show","todos"], ["root","fact","list","todos","--evolution","abc123"],
    ["root","fact","show","todos","one","--evolution","abc123"]] refuses
  let key = either error id (secretName "JEV_TOKEN")
  succeeds ["secret","set","JEV_TOKEN"] (Invocation selected Human (Secret (SetSecret key Nothing)))
  succeeds ["secret","set","JEV_TOKEN","fixture-secret"]
    (Invocation selected Human (Secret (SetSecret key (Just (SecretArgument "fixture-secret")))))
  succeeds ["secret","list"] (Invocation selected Human (Secret ListSecrets))
  succeeds ["secret","show","JEV_TOKEN"] (Invocation selected Human (Secret (ShowSecret key)))
  succeeds ["secret","remove","JEV_TOKEN"] (Invocation selected Human (Secret (RemoveSecret key)))
  assert "Show leaks secret" (not ("fixture-secret" `isInfixOf` show (SecretArgument "fixture-secret")))
  forM_ [["secret","set","../escape","x"], ["secret","show"], ["secret","remove",""]] refuses
  succeeds ["root","recipe","list"] (Invocation selected Human (Root (RootRecipe ListRecipes)))
  forM_ [([],Tree),(["--dot"],Dot),(["--mermaid"],Mermaid)] $ \(flags,format) ->
    succeeds (["root","recipe","describe","syncTodos"] ++ flags)
      (Invocation selected Human (Root (RootRecipe (DescribeRecipe (RecipeId "syncTodos") format))))
  forM_ [["root","recipe","describe"], ["root","recipe","describe","syncTodos","--dot","--mermaid"],
    ["root","recipe","describe","syncTodos","--evolution","abc123"]] refuses
  succeeds ["root","recipe","show","syncTodos"]
    (Invocation selected Human (Root (RootRecipe (ShowRecipe (RecipeId "syncTodos")))))
  succeeds ["root","recipe","run","syncTodos","local-file","sales","local-file","sales"]
    (Invocation selected Human (Root (RootRecipe (RunRecipe (RecipeId "syncTodos") [(localFile,sales),(localFile,sales)]))))
  forM_ [["root","recipe","run","syncTodos"], ["root","recipe","run","syncTodos","local-file"],
    ["root","recipe","run","syncTodos","local-file","sales","local-file"]] refuses
  succeeds ["root","recipe","pending","list","syncTodos","local-file","sales"]
    (Invocation selected Human (Root (RootRecipe (ListPendingEvidence (RecipeId "syncTodos") localFile sales))))
  forM_ [["root","recipe","show","bad-name"], ["root","recipe","pending","list","syncTodos"],
    ["root","recipe","list","--evolution","abc123"]] refuses
  succeeds ["root","tool","list"] (Invocation selected Human (Root (RootTool (ListTools Nothing))))
  succeeds ["root","tool","show","content","--evolution","abc123"]
    (Invocation selected Human (Root (RootTool (ShowTool content (Just identity)))))
  succeeds ["root","tool","execute","content","--input","[\"one.txt\"]"]
    (Invocation selected Human (Root (RootTool (ExecuteTool content "[\"one.txt\"]"))))
  forM_ [["root","tool","execute","content"], ["root","tool","show","case"],
    ["root","tool","execute","content","--input","[]","--evolution","abc123"]] refuses
  succeeds ["kb","init"] (Invocation selected Human (Kb InitKb))
  succeeds ["plugin", "list"] (Invocation selected Human (Plugin (ListPlugins Nothing)))
  succeeds ["plugin", "show", "local-file", "--evolution", "abc123"]
    (Invocation selected Human (Plugin (ShowPlugin localFile (Just identity))))
  succeeds ["plugin", "guide", "local-file"] (Invocation selected Human (Plugin (ReadPluginGuide (InstalledGuide localFile) Nothing)))
  let community = either error id (tapName "community")
      source = either error id (gitUrl "file:///catalogue")
  succeeds ["tap", "list"] (Invocation selected Human (Tap ListTaps))
  succeeds ["tap", "add", "community", "--from", "file:///catalogue"] (Invocation selected Human (Tap (AddTap community source)))
  succeeds ["tap", "update"] (Invocation selected Human (Tap (UpdateTaps Nothing)))
  succeeds ["tap", "update", "community"] (Invocation selected Human (Tap (UpdateTaps (Just community))))
  succeeds ["plugin", "search", "calendar"] (Invocation selected Human (Plugin (SearchPlugins "calendar")))
  succeeds ["plugin", "install", "community/local-file", "--evolution", "abc123"]
    (Invocation selected Human (Plugin (InstallAvailablePlugin identity community localFile)))
  succeeds ["plugin", "guide", "community/local-file"]
    (Invocation selected Human (Plugin (ReadPluginGuide (AvailableGuide community localFile) Nothing)))
  forM_ [["tap","add","../bad","--from","file:///catalogue"], ["plugin","install","community/local-file"],
    ["plugin","install","community/local-file","--from","file:///catalogue","--evolution","abc123"]] refuses
  refuses ["plugin", "guide", "../bad"]
  succeeds ["plugin","install","--evolution","abc123","--from","./plugins/local-file"]
    (Invocation selected Human (Plugin (InstallPlugin identity "./plugins/local-file" Nothing)))
  succeeds ["--kb","nested/kb","--json","plugin","install","--evolution","abc123","--from","file:///repo","--path","plugins/local-file"]
    (Invocation (Selection "nested/kb" Nothing Nothing) Json (Plugin (InstallPlugin identity "file:///repo" (Just "plugins/local-file"))))
  refuses ["plugin","install","--from","./plugins/local-file"]
  refuses ["plugin","install","--evolution","../bad","--from","./plugins/local-file"]
  succeeds ["plugin","connector","list","local-file"]
    (Invocation selected Human (Plugin (Connector (ListConnectors localFile Nothing))))
  succeeds ["plugin","connector","schema","show","local-file","--evolution","abc123"]
    (Invocation selected Human (Plugin (Connector (ShowConnectorSchema localFile (Just identity)))))
  succeeds ["evidence","fetch","local-file","sales"]
    (Invocation selected Human (Evidence (FetchConnector localFile sales Nothing)))
  succeeds ["evidence","fetch","local-file","sales","--options","{ limit = 3 }"]
    (Invocation selected Human (Evidence (FetchConnector localFile sales (Just "{ limit = 3 }"))))
  succeeds ["plugin","connector","show","local-file","sales"]
    (Invocation selected Human (Plugin (Connector (ShowConnector localFile sales Nothing))))
  succeeds ["plugin","connector","login","local-file","sales"]
    (Invocation selected Human (Plugin (Connector (LoginConnector localFile sales))))
  refuses ["plugin","connector","login","local-file","sales","--evolution","abc123"]
  refuses ["evidence","fetch","local-file","sales","--options"]
  succeeds ["plugin","connector","method","list","local-file","sales","--evolution","abc123"]
    (Invocation selected Human (Plugin (Connector (ListConnectorMethods localFile sales (Just identity)))))
  succeeds ["plugin","connector","method","show","local-file","sales","content"]
    (Invocation selected Human (Plugin (Connector (ShowConnectorMethod localFile sales content Nothing))))
  succeeds ["plugin","connector","method","execute","local-file","sales","content","--input","\"one.txt\""]
    (Invocation selected Human (Plugin (Connector (ExecuteConnectorMethod localFile sales content "\"one.txt\""))))
  refuses ["plugin","connector","method","execute","local-file","sales","content","--input","\"one.txt\"","--evolution","abc123"]
  refuses ["plugin","connector","method","execute","local-file","sales","content"]
  refuses ["plugin","connector","method","show","local-file","sales","case"]
  succeeds ["evidence","history","list","local-file","sales"]
    (Invocation selected Human (Evidence (ListFetchHistory localFile sales)))
  succeeds ["evidence","list","local-file","sales"]
    (Invocation selected Human (Evidence (ListCurrentEvidence localFile sales)))
  forM_ [["evidence","list"], ["evidence","list","local-file"],
    ["evidence","list","local-file","sales","--since","first"],
    ["evidence","list","local-file","sales","--evolution","abc123"]] refuses
  succeeds ["evidence","change","list","local-file","sales","--since","first"]
    (Invocation selected Human (Evidence (ListEvidenceChanges localFile sales (Just (FetchId "first")))))
  succeeds ["evidence","clear","local-file","sales"]
    (Invocation selected Human (Evidence (ClearEvidence localFile sales)))
  forM_ [["evidence","fetch","local-file","sales","--evolution","abc123"],
    ["plugin","connector","fetch","local-file","sales"],
    ["evidence","fetch","local-file",""],
    ["evidence","change","list","local-file","sales","--since",""],
    ["evidence","clear","local-file",""]] refuses
  succeeds ["root","check"] (Invocation selected Human (Root CheckRoot))
  succeeds ["--kb","knowledge/sales","--json","--git","/bin/git",
    "--runtime","/opt/kyyn/lib/kyyn","evolution","list","--exclude-drafts"]
    (Invocation (Selection "knowledge/sales"
      (Just "/bin/git") (Just "/opt/kyyn/lib/kyyn")) Json (Evolution (ListEvolutions ExcludeDrafts)))
  succeeds ["evolution","list"] (Invocation selected Human (Evolution (ListEvolutions AllEvolutions)))
  succeeds ["guest","module","list"] (Invocation selected Human (Guest Nothing ListGuestModules))
  succeeds ["guest","module","show","Kyyn.Edit"] (Invocation selected Human (Guest Nothing (ShowGuestModule "Kyyn.Edit")))
  succeeds ["guest","symbol","show","Kyyn.Evolution.>=>"]
    (Invocation selected Human (Guest Nothing (ShowGuestSymbol "Kyyn.Evolution.>=>")))
  forM_ [(["module","list"],ListGuestModules),
    (["module","show","Kyyn.Workspace.Evolution"],ShowGuestModule "Kyyn.Workspace.Evolution"),
    (["symbol","show","Kyyn.Workspace.After.todos"],ShowGuestSymbol "Kyyn.Workspace.After.todos")] $ \(args,request) -> do
      succeeds (["--kb","nested/kb","--runtime","/runtime","--json","guest"] ++ args ++ ["--evolution","abc123"])
        (Invocation (Selection "nested/kb" Nothing (Just "/runtime")) Json (Guest (Just identity) request))
      refuses (["guest"] ++ args ++ ["--evolution","../invalid"])
  succeeds ["evolution","new","September"]
    (Invocation selected Human (Evolution (NewEvolution (EvolutionName "September") Nothing)))
  succeeds ["evolution","new","September","--before",replicate 40 'a']
    (Invocation selected Human (Evolution (NewEvolution (EvolutionName "September") (Just revision))))
  forM_ [("show",ShowEvolution),("check",CheckEvolution),
    ("ready",ReadyEvolution),("draft",DraftEvolution),("accept",AcceptEvolution),("recover",RecoverEvolution)] $
    \(verb,constructor) -> do
      succeeds ["evolution",verb,"abc123"] (Invocation selected Human (Evolution (constructor identity)))
      let numbered = either error id (evolutionId "000001-add-review-status")
      succeeds ["evolution",verb,"000001-add-review-status"] (Invocation selected Human (Evolution (constructor numbered)))
  forM_ [["evolution","evaluate","abc123"],["root","delete"],["evolution","accept"],["evolution","accept","Monthly"],
    ["evolution","new",""],["evolution","new","example","--before","HEAD"],
    ["--repository",".","root","show"],
    ["plugin","install"], ["plugin","install","--from"], ["root","show","extra"]] refuses
  forM_ [[],["root"],["evolution"],["--help"],["evolution","accept","--help"]] $ \args ->
    case parseArguments args of
      Failure failure -> do
        let (message,status) = renderFailure failure "kyyn"
        assert "Help omitted usage" ("Usage:" `isInfixOf` message)
        assert "Wrong help exit status"
          (status == if "--help" `elem` args then ExitSuccess else ExitFailure 2)
      _ -> fail ("Expected help: " ++ show args)
  forM_ [([], ["kb", "root", "evolution", "guest", "plugin", "evidence"]), (["plugin"], ["install", "list", "show", "guide", "connector"]),
    (["evidence"], ["fetch", "history", "change"]), (["plugin", "connector"], ["list", "schema"]),
    (["kb"], ["init"]), (["root"], ["show", "check"]),
    (["guest"], ["module", "symbol"]), (["guest", "module"], ["list", "show"]),
    (["evolution"], ["new", "list", "accept"]),
    (["root", "unknown"], ["show", "check"])] $ \(args,commands) ->
    case parseArguments args of
      Failure failure -> do
        let (message,status) = renderFailure failure "kyyn-v2"
        assert "Incomplete or invalid command should exit 2" (status == ExitFailure 2)
        assert "Help omitted command list" ("Available commands:" `isInfixOf` message)
        forM_ commands $ \command ->
          assert ("Help omitted " ++ command) (("  " ++ command ++ " ") `isInfixOf` message)
      _ -> fail ("Expected command help: " ++ show args)
  putStrLn "CLI selection, command routing, refusals and help passed."
