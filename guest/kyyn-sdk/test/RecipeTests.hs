{-# LANGUAGE OverloadedStrings #-}
module RecipeTests (main) where

import Control.Monad (unless)
import Kyyn.Recipe
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))

main :: IO ()
main = do
  let request = RecipeInput ("root" :: String) True (3 :: Int)
      check label ok = unless ok (fail label)
  case request of
    RecipeInput root input state -> do
      check "caller input stays separate from state" (root == "root" && input && state == 3)
      let result = RecipeProposal [] (state + 1) :: RecipeProposal (FactEdit String) Int
      check "state-only proposals need no fact edits" (result == RecipeProposal [] 4)
  let rationale = Rationale "Record the result" []
      fact = Fact (FactId "one") ("done" :: String)
      proposal = RecipeProposal [ProposedStep rationale [Append fact]] ()
  check "stateless recipes carry unit state"
    (proposal == RecipeProposal [ProposedStep rationale [Append fact]] ())
