-- Complete pure preparation/projection/edit boundary with compiled target codecs.
-- Exercises empty collection defaults, explicit residual fields, retained recipe
-- checks and edited output invariants. No compiler discovery or host publication.
{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies, OverloadedStrings, TypeApplications #-}
module Main (main) where

import Control.Monad (unless)
import Data.Either (isLeft)
import Data.Text (Text)
import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.SchemaMetadata
import Kyyn.Types.GuestBuild (RecipeReference(..))
import Kyyn.Types.KnowledgeBase (Recipe(..), RecipeId(..))
import Kyyn.Evolution.Stored
import Kyyn.Evolution.Target
import Kyyn.Evolution.Preparation
import Kyyn.Runtime.TargetEvolution
import Kyyn.Runtime.Bindings (recipeType)
import qualified Kyyn.Recipe.Internal as Typed
import Kyyn.Edit (get, put)

data Root = Root { people :: [Fact Text], additional :: [Fact Text], total :: Integer }
  deriving stock (Eq, Show, Generic) deriving anyclass Contract

main :: IO ()
main = do
  value <- right (encodeFact (Fact (FactId "one") ("Ada" :: Text)))
  count <- right (encodeStored (0 :: Integer))
  state <- right (encodeStored False)
  stateType <- right (recipeType @Bool "Current.State")
  let metadata = SchemaMetadata [] [] [CollectionDecl "people" "people" [], CollectionDecl "additional" "additional" []]
      recipe = StoredRecipe (OpenAgent "Review") (Just "Current.State") state
      initial = StoredSnapshot [("total",count)] [("people",[Fact (FactId "one") value])] [Fact (FactId "weekly") recipe]
      reason = Rationale "Target migration" []
  binding <- right (targetBinding @Root metadata [RecipeBinding (OpenState "Current.State") stateType])
  (result,steps) <- right (evaluateEvolution binding reason identityEvolution initial)
  assert "target empty collection not introduced" (case result of
    Typed.KnowledgeBase (Root [_] [] 0) [_] -> True
    _ -> False)
  assert "target projection is not explicitly observed" (case steps of
    [Observation TargetProjection _ before (StoredSnapshot _ collections _)] ->
      before == initial && lookup "additional" collections == Just []
    _ -> False)
  let mutate = edit reason $ do
        Typed.KnowledgeBase (Root facts extras _) recipes <- get
        put (Typed.KnowledgeBase (Root facts extras 4) recipes)
      evolution = prepare (putField reason (TargetField "total") (3 :: Integer)) mutate
  (changed,observations) <- right (evaluateEvolution binding reason evolution initial)
  assert "typed edits not applied after preparation" (case changed of Typed.KnowledgeBase (Root _ _ 4) _ -> True; _ -> False)
  assert "step origins/order lost" ([origin | Observation origin _ _ _ <- observations] == [Authored,TargetProjection,Authored])
  assert "chain broken" (and [after == before |
    (Observation _ _ _ after,Observation _ _ before _) <- zip observations (drop 1 observations)])
  let reject label snapshot = assert label (isLeft (evaluateEvolution binding reason identityEvolution snapshot))
  reject "missing residual field defaulted" (StoredSnapshot [] [("people",[])] [])
  reject "extra residual field ignored" (StoredSnapshot [("total",count),("extra",count)] [] [])
  reject "old collection silently dropped" (StoredSnapshot [("total",count)] [("old",[])] [])
  reject "member/envelope mismatch accepted" (StoredSnapshot [("total",count)] [("people",[Fact (FactId "wrong") value])] [])
  reject "duplicate members accepted" (StoredSnapshot [("total",count)] [("people",replicate 2 (Fact (FactId "one") value))] [])
  reject "unresolved recipe retained" (StoredSnapshot [("total",count)] []
    [Fact (FactId "weekly") (StoredRecipe (OpenAgent "Review") (Just "Absent.State") state)])
  reject "wrong recipe state accepted" (StoredSnapshot [("total",count)] []
    [Fact (FactId "weekly") (StoredRecipe (OpenAgent "Review") (Just "Current.State") count)])
  let obsolete = StoredSnapshot [("total",count)] []
        [Fact (FactId "weekly") (StoredRecipe (OpenAgent "Review") (Just "Absent.State") state)]
  _ <- right (evaluateEvolution binding reason (prepare (retireRecipe reason (RecipeId "weekly")) mempty) obsolete)
  assert "invalid typed output accepted" (isLeft (evaluateEvolution binding reason
    (prepare (pure ()) (edit reason $ do
      Typed.KnowledgeBase (Root _ extras n) recipes <- get
      put (Typed.KnowledgeBase (Root (replicate 2 (Fact (FactId "one") "Ada")) extras n) recipes))) initial))
  putStrLn "Target projection and edit checks passed"

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
