{-# LANGUAGE OverloadedStrings, TypeApplications #-}
module Main where

import qualified Agentic as A
import qualified Data.Text as T
import Control.Monad.Trans.Except (runExceptT)
import Kyyn.Runtime.Plugin (execute)
import qualified Kyyn.Runtime.Json as J
import Kyyn.Runtime.Evolution (encodeEvolutionReply)
import qualified Kyyn.Evolution.Internal as E
import Kyyn.Evolution (withCuration, Curation(..), RecipeId(..), Acknowledgement(..), EvidenceScope(..), EvidenceId(..))
import System.Environment (getArgs)
import Bridge
import Proposal

flow :: A.Agentic Guest T.Text [ProposedStep]
flow = A.draftWith @[ProposedStep]
  [A.tool @T.Text @T.Text "review" "Review evidence" (A.draft @T.Text "Review this evidence")]
  "Propose fact edits"

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["apply"] -> do
      -- Frozen data, not another run of the model-backed flow.
      line <- getLine
      value <- either fail pure (J.parseValue line >>= J.decodeWith valueCodec)
      steps <- either (fail . T.unpack) pure (A.decode A.contract value)
      let selected = withCuration (Curation (RecipeId "sync")
            [IndividualRecords (EvidenceScope "fixture" "files" "fetch-1") [EvidenceId "e-1"]])
            (proposalEvolution steps)
      either fail putStrLn (encodeEvolutionReply rootCodec (E.evaluateEvolution selected before))
    ["describe"] -> putStrLn (T.unpack (A.renderTree (A.describe flow)))
    [] -> execute resultCodec modelRequest (runExceptT (A.interpret runtime flow "captured evidence 雪"))
    _ -> fail "Expected apply, describe or no arguments"
  where
    resultCodec = J.Codec
      (either (J.tagged "Left" . Just . J.encodeWith J.stringCodec)
        (J.tagged "Right" . Just . J.encodeWith valueCodec . A.encode A.contract))
      (const (Left "Flow result is output only"))
