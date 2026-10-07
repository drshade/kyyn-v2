-- Typed recipe state persistence: hermetic Dhall, per-ID isolation, unit state,
-- rejected missing/extra/malformed files, contract mismatch and selected-pair
-- decoding that preserves unrelated recipes. No publication.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (object, (.=), Value(..), encode)
import qualified Data.ByteString.Char8 as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Effectful (runPureEff)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Recipe (RecipeId(..))
import Kyyn.Domain.FileTree (files, fileTree)
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Domain.Recipe (StoredRecipe(..), recipeDefinition, proposedRecipe, KnowledgeBase(..), ProposedRecipe(..))
import Kyyn.Domain.EvolutionReport (EvolutionObservation(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Porcelain.Protocol.RecipePersistence
import Kyyn.Plumbing.Protocol.RecipeEvolution (decodeRecipeEvolutionReply)

main :: IO ()
main = do
  state <- right (checkContract (Algebraic "Review.State" []
    [Constructor "Review.State" [(Just "seen",ListType StringType)]]) (SchemaMetadata [] [] []))
  unit <- right (checkContract UnitType (SchemaMetadata [] [] []))
  let first = RecipeId "mail"
      second = RecipeId "calendar"
      third = RecipeId "stateless"
      value ids = CheckedValue (contractId state) (object ["seen" .= (ids :: [String])])
      unitValue = CheckedValue (contractId unit) (object [])
      entries = [(first,state,value ["one"]),(second,state,value ["two"]),(third,unit,unitValue)]
      contracts = [(ident,contract) | (ident,contract,_) <- entries]
      run = runPureEff . runDhallHandling
  tree <- right (run (encodeRecipeStates entries))
  restored <- right (run (decodeRecipeStates contracts tree))
  assert "State values mixed between recipes sharing a type"
    (restored == [(ident,checked) | (ident,_,checked) <- entries])
  again <- right (run (encodeRecipeStates [(ident,contract,checked) |
    ((ident,contract),(_,checked)) <- zip contracts restored]))
  assert "Untouched canonical state changed bytes" (files tree == files again)
  assert "Unit state is stored as Dhall" (maybe False (Bytes.isInfixOf "{=}")
    (lookup (path "recipes/stateless/state.dhall") (files tree)))
  empty <- right (fileTree [])
  assert "Missing state initialized itself" (isFailure (run (decodeRecipeStates contracts empty)))
  assert "Orphan state was ignored" (isFailure (run (decodeRecipeStates [] tree)))
  assert "Duplicate ID accepted" (isFailure (run (encodeRecipeStates (entries ++ entries))))
  assert "Path traversal accepted" (isFailure (run
    (encodeRecipeStates [(RecipeId "../escape",unit,unitValue)])))
  assert "CheckedValue from a different contract accepted" (isFailure (run
    (encodeRecipeStates [(third,unit,value [])])))
  assert "Claimed identity bypasses host value checking" (isFailure (run
    (encodeRecipeStates [(third,unit,CheckedValue (contractId unit) (String "not unit"))])))
  malformed <- right (fileTree [(path "recipes/stateless/state.dhall","\"not unit\"")])
  assert "Malformed stored state accepted" (isFailure (run (decodeRecipeStates [(third,unit)] malformed)))
  imported <- right (fileTree [(path "recipes/stateless/state.dhall","./external.dhall")])
  assert "Dhall import accepted in stored state" (isFailure (run (decodeRecipeStates [(third,unit)] imported)))
  let stored =
        [ Fact (FactId "mail") (StoredRecipe (OpenAgent "Review mail") "Review.State" state (value ["one"]))
        , Fact (FactId "calendar") (StoredRecipe (ClosedAgent (FlowEntryRef "Flows.calendar")) "Review.State" state (value ["two"]))
        , Fact (FactId "stateless") (StoredRecipe (OpenAgent "Investigate") "()" unit unitValue)
        ]
      resolved = [(Fact ident (recipeDefinition recipe),name,contract) |
        Fact ident recipe@(StoredRecipe _ name contract _) <- stored]
  storedTree <- right (run (encodeStoredRecipes stored))
  definitions <- right (run (decodeRecipes (lookup (path "recipes.dhall") (files storedTree))))
  assert "Definitions redundantly store closed-flow state type"
    (definitions == [definition | (definition,_,_) <- resolved])
  storedAgain <- right (run (decodeStoredRecipes resolved storedTree))
  assert "Stored recipe values or identities changed" (storedAgain == stored)
  canonicalAgain <- right (run (encodeStoredRecipes storedAgain))
  assert "Unchanged recipe material produced different bytes" (files canonicalAgain == files storedTree)
  snapshots <- right (run (encodeRecipeContracts stored))
  restoredSnapshots <- right (run (decodeRecipeContracts snapshots))
  assert "Candidate contract snapshots lost their recipe identity"
    (restoredSnapshots == [(ident,name,contract) | (Fact ident _,name,contract) <- resolved])
  let pair = object ["facts" .= object [], "state" .= object ["seen" .= (["three"] :: [String])]]
      reply after = Lazy.toStrict (encode (object ["tag" .= ("Succeeded" :: String), "value" .= object
        ["after" .= after, "steps" .= ([] :: [Value])]]))
      expected = [Fact ident (case proposedRecipe recipe of
        ProposedRecipe method name identity stateValue -> ProposedRecipe method name identity
          (if ident == FactId "mail" then object ["seen" .= (["three"] :: [String])] else stateValue)) |
        Fact ident recipe <- stored]
  decoded <- right (decodeRecipeEvolutionReply first stored (reply pair)) >>= right
  assert "Recipe pair decoding changed another recipe or its definition"
    (decoded == EvolutionObservation (KnowledgeBase (object []) expected) [])
  assert "Missing selected recipe was accepted"
    (isFailure (decodeRecipeEvolutionReply (RecipeId "missing") stored (reply pair)))
  assert "Duplicate selected recipe was accepted"
    (isFailure (decodeRecipeEvolutionReply first (stored ++ stored) (reply pair)))
  assert "Recipe pair accepted unrelated fields"
    (isFailure (decodeRecipeEvolutionReply first stored (reply (object
      ["facts" .= object [], "state" .= object [], "recipes" .= ([] :: [Value])]))))
  putStrLn "Typed per-recipe Dhall persistence passed."

path :: String -> RelativePath
path = either error id . relativePath

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

isFailure :: Either e a -> Bool
isFailure (Left _) = True
isFailure (Right _) = False
