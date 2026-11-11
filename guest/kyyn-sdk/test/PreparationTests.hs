-- Pure preparation checks: exact stored-shape decoding, chained reads, ID-set
-- preservation, explicit deletions/renames, destination collisions and recipe
-- state conversion. Host capture, target projection and publication are separate.
{-# LANGUAGE ScopedTypeVariables, DeriveGeneric, DeriveAnyClass, DerivingStrategies, OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless)
import Data.Either (isLeft)
import Data.Text (Text)
import GHC.Generics (Generic)
import Data.Aeson (Value(..))
import Kyyn.Contract (Contract)
import Kyyn.Types.Evolution (Rationale(..), EvolutionFailure)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (Recipe(..), RecipeId(..))
import Kyyn.Types.StoredShape
import Kyyn.Evolution.Stored
import Kyyn.Evolution.Preparation
import Kyyn.Edit.Internal (Collection(..))
import Kyyn.Recipe.Internal (KnowledgeBase(..), RecipeDefinition(..), RecipeType(..))
import Kyyn.Optics (lens)

data Old = Old { fullName :: Text } deriving stock (Eq, Show, Generic) deriving anyclass Contract
data New = New { name :: Text, active :: Bool } deriving stock (Eq, Show, Generic) deriving anyclass Contract

main :: IO ()
main = do
  old <- right (encodeStored (Fact (FactId "one") (Old "Ada")))
  count <- right (encodeStored (2 :: Integer))
  state <- right (encodeStored False)
  let initial = StoredSnapshot [("count",count)] [("people",[Fact (FactId "one") old])]
        [Fact (FactId "weekly") (StoredRecipe (OpenAgent "old") (Just "Old.State") state)]
      target = Collection "people" (lens (\(KnowledgeBase values _) -> values)
        (\(KnowledgeBase _ recipes) values -> KnowledgeBase values recipes))
        :: Collection (KnowledgeBase [Fact New]) New
      renamed = Collection "renamed" (lens (\(KnowledgeBase values _) -> values)
        (\(KnowledgeBase _ recipes) values -> KnowledgeBase values recipes))
        :: Collection (KnowledgeBase [Fact New]) New
      convert = traverse (\(Fact ident (Old value)) -> Right (Fact ident (New value True)))
      reason = Rationale "Explicit migration" []
      field = TargetField "total" :: TargetField [Fact New] Integer
      recipe = RecipeDefinition (OpenAgent "new")
        (RecipeType "New.State" "target" StoredBool Bool
          (\value -> case value of Bool result -> Right result; _ -> Left "expected boolean"))
      action = do
        migrateCollection reason "people" target convert
        values <- readCollection "people"
        renameCollection reason "people" renamed
        migrateField reason "count" field (\value -> Right (value + 1 :: Integer))
        migrateRecipe reason (RecipeId "weekly") recipe (\value -> Right (not value))
        total <- readField "total"
        remembered <- readRecipeState (RecipeId "weekly")
        pure (values,total :: Integer,remembered :: Bool)
  ((values,total,remembered),_,observations) <- right (runPreparation action initial)
  assert "converted facts not visible to subsequent reads" (values == [Fact (FactId "one") (New "Ada" True)])
  assert "field/state changes not visible" (total == 3 && remembered)
  assert "reads fabricate observations" (length observations == 4)
  assert "observation chain is discontinuous" (and
    [after == before | (Observation _ _ _ after,Observation _ _ before _) <- zip observations (drop 1 observations)])
  let rejects label step = assert label (isLeft (runPreparation step initial))
  rejects "ID change accepted" (migrateCollection reason "people" target
    (\(_ :: [Fact Old]) -> Right [Fact (FactId "new") (New "Ada" True)]))
  rejects "duplicate output accepted" (migrateCollection reason "people" target
    (\(_ :: [Fact Old]) -> Right [Fact (FactId "one") (New "Ada" True),Fact (FactId "one") (New "Ada" True)]))
  rejects "missing source accepted" (renameCollection reason "absent" target)
  rejects "missing fact accepted" (removeFact reason "people" (FactId "absent"))
  rejects "wrong input shape accepted" (migrateCollection reason "people" target (Right :: [Fact New] -> Either EvolutionFailure [Fact New]))
  rejects "field collision accepted" (putField reason field 3 >> renameField reason "count" field)
  let StoredSnapshot initialFields initialCollections initialRecipes = initial
      occupied = StoredSnapshot initialFields (("renamed",[]) : initialCollections) initialRecipes
  assert "collection collision accepted"
    (isLeft (runPreparation (renameCollection reason "people" renamed) occupied))
  (_,removed,removals) <- right (runPreparation (do
    removeFact reason "people" (FactId "one")
    migrateCollection reason "people" target convert
    removeCollection reason "people"
    removeField reason "count"
    retireRecipe reason (RecipeId "weekly")) initial)
  assert "explicit removal did not remove storage" (removed == StoredSnapshot [] [] [])
  assert "removal observations lost" (length removals == 5)
  empty <- right (encodeStored ([] :: [Text]))
  assert "empty list annotation mismatch accepted"
    (isLeft (decodeStored empty :: Either EvolutionFailure [Integer]))
  putStrLn "Typed snapshot preparation checks passed"

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
