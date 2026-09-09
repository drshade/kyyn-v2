module Main (main) where

import Control.Monad (forM_, unless)
import Data.List (isInfixOf)
import Kyyn.Domain.Evolution (EvolutionName(..), EvolutionFilter(..), evolutionId)
import Kyyn.Domain.Git (gitRevision)
import Kyyn.Surfaces.Cli
import Options.Applicative (ParserResult(..), renderFailure)
import System.Exit (ExitCode(..))

main :: IO ()
main = do
  let selected = Selection "." Nothing Nothing
      identity = either error id (evolutionId "abc123")
      revision = either error id (gitRevision (replicate 40 'a'))
      assert label condition = unless condition (fail label)
      succeeds args expected = case parseArguments args of
        Success actual -> assert ("Wrong parse: " ++ show args ++ ": " ++ show actual) (actual == expected)
        _ -> fail ("Parse failed: " ++ show args)
      refuses args = case parseArguments args of
        Failure failure -> let (_,status) = renderFailure failure "kyyn"
                           in assert ("Expected refusal: " ++ show args) (status /= ExitSuccess)
        _ -> fail ("Unexpectedly accepted: " ++ show args)
  succeeds ["root","show"] (Invocation selected Human (Root ShowRoot))
  succeeds ["root","check"] (Invocation selected Human (Root CheckRoot))
  succeeds ["--kb","knowledge/sales","--json","--git","/bin/git",
    "--runtime","/opt/kyyn/lib/kyyn","evolution","list","--exclude-drafts"]
    (Invocation (Selection "knowledge/sales"
      (Just "/bin/git") (Just "/opt/kyyn/lib/kyyn")) Json (Evolution (ListEvolutions ExcludeDrafts)))
  succeeds ["evolution","list"] (Invocation selected Human (Evolution (ListEvolutions AllEvolutions)))
  succeeds ["evolution","new","September"]
    (Invocation selected Human (Evolution (NewEvolution (EvolutionName "September") Nothing)))
  succeeds ["evolution","new","September","--before",replicate 40 'a']
    (Invocation selected Human (Evolution (NewEvolution (EvolutionName "September") (Just revision))))
  forM_ [("show",ShowEvolution),("evaluate",EvaluateEvolution),("check",CheckEvolution),
    ("ready",ReadyEvolution),("draft",DraftEvolution),("accept",AcceptEvolution),("recover",RecoverEvolution)] $
    \(verb,constructor) -> succeeds ["evolution",verb,"abc123"]
      (Invocation selected Human (Evolution (constructor identity)))
  forM_ [["root","delete"],["evolution","accept"],["evolution","accept","Monthly"],
    ["evolution","new",""],["evolution","new","example","--before","HEAD"],
    ["--repository",".","root","show"],["plugin","list"],
    ["root","show","extra"]] refuses
  forM_ [[],["root"],["evolution"],["--help"],["evolution","accept","--help"]] $ \args ->
    case parseArguments args of
      Failure failure -> let (message,_) = renderFailure failure "kyyn"
                         in assert "Help omitted usage" ("Usage:" `isInfixOf` message)
      _ -> fail ("Expected help: " ++ show args)
  putStrLn "CLI selection, command routing, refusals and help passed."
