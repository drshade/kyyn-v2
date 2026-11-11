{-# LANGUAGE GeneralizedNewtypeDeriving, OverloadedStrings, ScopedTypeVariables, TypeApplications #-}
-- Internal module; the facade exports abstract Preparation and TargetField types.
module Kyyn.Evolution.Preparation
  ( Preparation, TargetField(..), runPreparation
  , readCollection, migrateCollection, renameCollection, removeCollection, removeFact
  , readField, migrateField, putField, renameField, removeField
  , readRecipeState, migrateRecipe, retireRecipe
  ) where

import Control.Monad (unless)
import Control.Monad.Trans.State.Strict (StateT(..), runStateT, get)
import Control.Monad.Trans.Class (lift)
import Data.List (nub, sort)
import Data.Text (Text)
import Kyyn.Contract (Contract)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (RecipeId(..), Recipe(..))
import Kyyn.Types.Evolution (EvolutionFailure, Rationale)
import Kyyn.Edit.Internal (Collection(..))
import Kyyn.Recipe.Internal (KnowledgeBase, RecipeDefinition(..), RecipeType(..))
import Kyyn.Evolution.Stored

newtype Preparation root a = Preparation (StateT (StoredSnapshot,[Observation]) (Either EvolutionFailure) a)
  deriving (Functor, Applicative, Monad)
-- Generated only for residual fields; output is always checked with Contract.
newtype TargetField root value = TargetField Text

runPreparation :: Preparation root a -> StoredSnapshot
  -> Either EvolutionFailure (a,StoredSnapshot,[Observation])
runPreparation (Preparation action) snapshot = do
  (value,(result,observations)) <- runStateT action (snapshot,[])
  pure (value,result,observations)

readSnapshot :: (StoredSnapshot -> Either EvolutionFailure a) -> Preparation root a
readSnapshot action = Preparation $ do
  (snapshot,_) <- get
  lift (action snapshot)

mutate :: Rationale -> (StoredSnapshot -> Either EvolutionFailure StoredSnapshot) -> Preparation root ()
mutate rationale action = Preparation $ StateT $ \(before,observations) -> do
  after <- action before
  pure ((),(after, observations ++ [Observation Authored rationale before after]))

required :: Eq k => Text -> k -> [(k,a)] -> Either EvolutionFailure a
required label key entries = case [value | (name,value) <- entries, name == key] of
  [value] -> Right value
  _ -> failure ("Missing or duplicate " <> label)

replace :: Eq k => k -> a -> [(k,a)] -> [(k,a)]
replace key value entries = (key,value) : filter ((/= key) . fst) entries

rename :: Eq k => k -> k -> a -> [(k,a)] -> Either EvolutionFailure [(k,a)]
rename source target value entries = do
  unless (source == target || target `notElem` map fst entries) (failure "Destination already exists")
  pure (replace target value (filter ((/= source) . fst) entries))

readCollection :: Contract input => Text -> Preparation root [Fact input]
readCollection name = readSnapshot $ \(StoredSnapshot _ collections _) ->
  required ("collection " <> name) name collections >>= traverse (\(Fact _ value) -> decodeFact value)

migrateCollection :: (Contract input, Contract output)
  => Rationale -> Text -> Collection (KnowledgeBase root) output
  -> ([Fact input] -> Either EvolutionFailure [Fact output]) -> Preparation root ()
migrateCollection rationale source (Collection target _) convert = mutate rationale $ \(StoredSnapshot fields collections recipes) -> do
  old <- required ("collection " <> source) source collections
  input <- traverse (\(Fact _ value) -> decodeFact value) old
  output <- convert input
  let ids values = [name | Fact (FactId name) _ <- values]
  unless (length (ids output) == length (nub (ids output)) && sort (ids old) == sort (ids output))
    (failure "Collection migration must preserve exactly the input ID set")
  values <- traverse (\member@(Fact identity _) -> Fact identity <$> encodeFact member) output
  changed <- rename source target values collections
  pure (StoredSnapshot fields changed recipes)

renameCollection :: Rationale -> Text -> Collection (KnowledgeBase root) output -> Preparation root ()
renameCollection rationale source (Collection target _) = mutate rationale $ \(StoredSnapshot fields collections recipes) -> do
  value <- required ("collection " <> source) source collections
  changed <- rename source target value collections
  pure (StoredSnapshot fields changed recipes)

removeCollection :: Rationale -> Text -> Preparation root ()
removeCollection rationale name = mutate rationale $ \(StoredSnapshot fields collections recipes) -> do
  _ <- required ("collection " <> name) name collections
  pure (StoredSnapshot fields (filter ((/= name) . fst) collections) recipes)

removeFact :: Rationale -> Text -> FactId -> Preparation root ()
removeFact rationale name identity = mutate rationale $ \(StoredSnapshot fields collections recipes) -> do
  values <- required ("collection " <> name) name collections
  _ <- required "fact" identity [(ident,value) | Fact ident value <- values]
  pure (StoredSnapshot fields (replace name [fact | fact@(Fact ident _) <- values, ident /= identity] collections) recipes)

readField :: Contract input => Text -> Preparation root input
readField name = readSnapshot $ \(StoredSnapshot fields _ _) -> required ("field " <> name) name fields >>= decodeStored

migrateField :: (Contract input, Contract output)
  => Rationale -> Text -> TargetField root output
  -> (input -> Either EvolutionFailure output) -> Preparation root ()
migrateField rationale source (TargetField target) convert = mutate rationale $ \(StoredSnapshot fields collections recipes) -> do
  value <- required ("field " <> source) source fields >>= decodeStored >>= convert >>= encodeStored
  changed <- rename source target value fields
  pure (StoredSnapshot changed collections recipes)

putField :: Contract output => Rationale -> TargetField root output -> output -> Preparation root ()
putField rationale (TargetField target) output = mutate rationale $ \(StoredSnapshot fields collections recipes) -> do
  value <- encodeStored output
  pure (StoredSnapshot (replace target value fields) collections recipes)

renameField :: Rationale -> Text -> TargetField root output -> Preparation root ()
renameField rationale source (TargetField target) = mutate rationale $ \(StoredSnapshot fields collections recipes) -> do
  value <- required ("field " <> source) source fields
  changed <- rename source target value fields
  pure (StoredSnapshot changed collections recipes)

removeField :: Rationale -> Text -> Preparation root ()
removeField rationale name = mutate rationale $ \(StoredSnapshot fields collections recipes) -> do
  _ <- required ("field " <> name) name fields
  pure (StoredSnapshot (filter ((/= name) . fst) fields) collections recipes)

readRecipeState :: Contract input => RecipeId -> Preparation root input
readRecipeState (RecipeId name) = readSnapshot $ \(StoredSnapshot _ _ recipes) -> do
  StoredRecipe _ _ state <- required ("recipe " <> name) (FactId name) [(ident,value) | Fact ident value <- recipes]
  decodeStored state

migrateRecipe :: Contract input => Rationale -> RecipeId -> RecipeDefinition output
  -> (input -> Either EvolutionFailure output) -> Preparation root ()
migrateRecipe rationale (RecipeId name) (RecipeDefinition method (RecipeType typeName _ shape encode _)) convert =
  mutate rationale $ \(StoredSnapshot fields collections recipes) -> do
    StoredRecipe _ _ state <- required ("recipe " <> name) (FactId name) [(ident,value) | Fact ident value <- recipes]
    output <- decodeStored state >>= convert
    let selected = StoredRecipe method
          (case method of OpenAgent _ -> Just typeName; ClosedAgent _ -> Nothing)
          (RecordedValue shape (encode output))
    pure (StoredSnapshot fields collections
      [Fact ident (if ident == FactId name then selected else value) | Fact ident value <- recipes])

retireRecipe :: Rationale -> RecipeId -> Preparation root ()
retireRecipe rationale (RecipeId name) = mutate rationale $ \(StoredSnapshot fields collections recipes) -> do
  _ <- required ("recipe " <> name) (FactId name) [(ident,value) | Fact ident value <- recipes]
  pure (StoredSnapshot fields collections [value | value@(Fact ident _) <- recipes, ident /= FactId name])
