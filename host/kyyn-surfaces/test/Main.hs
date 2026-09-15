module Main (main) where

import Control.Monad (forM_, unless)
import Data.List (isInfixOf)
import Kyyn.Domain.Evolution (EvolutionName(..), EvolutionFilter(..), evolutionId)
import Kyyn.Domain.Git (gitRevision)
import Kyyn.Domain.Plugin (pluginName, connectorName)
import Kyyn.Domain.Evidence (FetchId(..))
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
      assert label condition = unless condition (fail label)
      succeeds args expected = case parseArguments args of
        Success actual -> assert ("Wrong parse: " ++ show args ++ ": " ++ show actual) (actual == expected)
        _ -> fail ("Parse failed: " ++ show args)
      refuses args = case parseArguments args of
        Failure failure -> let (_,status) = renderFailure failure "kyyn"
                           in assert ("Expected usage exit 2: " ++ show args) (status == ExitFailure 2)
        _ -> fail ("Unexpectedly accepted: " ++ show args)
  succeeds ["root","show"] (Invocation selected Human (Root ShowRoot))
  succeeds ["kb","init"] (Invocation selected Human (Kb InitKb))
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
    (Invocation selected Human (Evidence (FetchConnector localFile sales)))
  succeeds ["evidence","history","list","local-file","sales"]
    (Invocation selected Human (Evidence (ListFetchHistory localFile sales)))
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
    ["--repository",".","root","show"],["plugin","list"],
    ["plugin","install"], ["plugin","install","--from"], ["root","show","extra"]] refuses
  forM_ [[],["root"],["evolution"],["--help"],["evolution","accept","--help"]] $ \args ->
    case parseArguments args of
      Failure failure -> do
        let (message,status) = renderFailure failure "kyyn"
        assert "Help omitted usage" ("Usage:" `isInfixOf` message)
        assert "Wrong help exit status"
          (status == if "--help" `elem` args then ExitSuccess else ExitFailure 2)
      _ -> fail ("Expected help: " ++ show args)
  forM_ [([], ["kb", "root", "evolution", "guest", "plugin", "evidence"]), (["plugin"], ["install", "connector"]),
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
