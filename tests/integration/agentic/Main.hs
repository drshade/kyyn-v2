{-# LANGUAGE OverloadedStrings, OverloadedRecordDot, TypeApplications, TypeOperators, PatternSynonyms #-}
module Main where

import qualified Agentic as A
import Agentic ((:/\), pattern (:/\))
import qualified Data.Text as T
import Control.Monad.Trans.Except (runExceptT)
import Kyyn.Runtime.Plugin (execute)
import Kyyn.Runtime.Transport (withTransport)
import qualified Kyyn.Runtime.Json as J
import Kyyn.Runtime.Evolution (encodeEvolutionReply)
import qualified Kyyn.Evolution.Internal as E
import System.Environment (getArgs)
import Bridge
import Proposal

flow :: A.Agentic Guest T.Text Proposal
flow = A.draftWith @Proposal
  [A.tool @T.Text @T.Text "review" "Review evidence" (A.draft @T.Text "Review this evidence")]
  "Propose fact edits"

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["pairs"] -> do
      let pair :: Int :/\ String :/\ Bool
          pair = 1 :/\ "two" :/\ True
          pick :: A.Agentic IO (Int :/\ String :/\ Bool) String
          pick = A.takeSecond A.>>> A.takeFirst
          diagram :: A.Agentic IO T.Text T.Text
          diagram = (A.draft @T.Text "first" A.&&& A.draft @T.Text "second")
            A.>>> A.takeSecond A.>>> A.draft @T.Text "last"
      selected <- A.interpret (error "Pure pair selection requested a runtime") pick pair
      case pair of
        _ :/\ text :/\ _ | selected == text -> pure ()
        _ -> fail "Pair selection changed"
      putStrLn (T.unpack (A.mermaid (A.describe diagram)))
      putStrLn (T.unpack (A.dot (A.describe diagram)))
    ["apply"] -> do
      -- Frozen data, not another run of the model-backed flow.
      line <- getLine
      value <- either fail pure (J.parseValue line >>= J.decodeWith valueCodec)
      Proposal steps <- either (fail . T.unpack) pure (((A.contract :: A.Codec Proposal).decode) value)
      let selected = proposalEvolution steps
      either fail putStrLn (encodeEvolutionReply rootCodec (E.evaluateEvolution selected before))
    ["describe"] -> putStrLn (T.unpack (A.renderTree (A.describe flow)))
    [] -> withTransport $ \transport -> execute transport resultCodec (modelRequest transport) (runExceptT (A.interpret runtime flow "captured evidence 雪"))
    _ -> fail "Expected apply, describe or no arguments"
  where
    resultCodec = J.Codec
      (either (J.tagged "Left" . Just . J.encodeWith J.stringCodec)
        (J.tagged "Right" . Just . J.encodeWith valueCodec . ((A.contract :: A.Codec Proposal).encode)))
      (const (Left "Flow result is output only"))
