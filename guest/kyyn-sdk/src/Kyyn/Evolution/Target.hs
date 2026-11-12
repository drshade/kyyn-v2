{-# LANGUAGE OverloadedStrings #-}
-- | The pure preparation-to-target boundary. Bindings are compiler-generated;
-- authored code sees only Evolution, TargetEdits, prepare and edit.
module Kyyn.Evolution.Target
  ( Evolution, TargetEdits, TargetBinding(..), prepare, edit, identityEvolution
  , evaluateEvolution
  ) where

import Control.Monad (foldM, unless)
import Data.List (sort, nub)
import Data.Text (Text)
import Data.Aeson (Value(..), toJSON)
import qualified Data.Aeson.KeyMap as Keys
import Data.Foldable (toList)
import qualified Data.Aeson.Key as Key
import Kyyn.Edit (Edit)
import Kyyn.Edit.Internal (execStateT)
import Kyyn.Types.Fact (Fact(..), FactId(..), parseFactId)
import Kyyn.Types.Evolution (EvolutionFailure(..), Rationale)
import Kyyn.Types.Diagnostic (Diagnostic(..))
import Kyyn.Types.StoredShape
import qualified Kyyn.Recipe.Internal as Typed
import Kyyn.Evolution.Stored
import Kyyn.Evolution.Preparation (Preparation, runPreparation)

data TargetBinding root = TargetBinding
  [(Text,Text)]
  StoredShape
  (RecordedValue -> Either EvolutionFailure root)
  (root -> Either EvolutionFailure RecordedValue)
  (StoredRecipe -> Either EvolutionFailure Typed.StoredRecipe)
  (Typed.StoredRecipe -> Either EvolutionFailure StoredRecipe)

newtype TargetEdits root = TargetEdits [(Rationale, Edit (Typed.KnowledgeBase root) ())]
instance Semigroup (TargetEdits root) where
  TargetEdits left <> TargetEdits right = TargetEdits (left ++ right)
instance Monoid (TargetEdits root) where
  mempty = TargetEdits []

data Evolution root = Evolution (Preparation root ()) (TargetEdits root)
prepare :: Preparation root () -> TargetEdits root -> Evolution root
prepare = Evolution
edit :: Rationale -> Edit (Typed.KnowledgeBase root) () -> TargetEdits root
edit rationale action = TargetEdits [(rationale,action)]
identityEvolution :: Evolution root
identityEvolution = prepare (pure ()) mempty

prepareEvolution :: Evolution root -> StoredSnapshot
  -> Either EvolutionFailure (StoredSnapshot,[Observation])
prepareEvolution (Evolution preparation _) input = do
  ((),result,observations) <- runPreparation preparation input
  pure (result,observations)

evaluateEvolution :: TargetBinding root -> Rationale -> Evolution root -> StoredSnapshot
  -> Either EvolutionFailure (Typed.KnowledgeBase root,[Observation])
evaluateEvolution binding rationale evolution input = do
  (prepared,earlier) <- prepareEvolution evolution input
  (output,later) <- evaluatePrepared binding rationale evolution prepared
  pure (output,earlier ++ later)

-- Target decoding is one pure boundary within the same evaluation.
evaluatePrepared :: TargetBinding root -> Rationale -> Evolution root -> StoredSnapshot
  -> Either EvolutionFailure (Typed.KnowledgeBase root,[Observation])
evaluatePrepared binding rationale (Evolution _ (TargetEdits edits)) before = do
  root <- project binding before
  projected <- record binding root
  let observation = Observation TargetProjection rationale before projected
  (result,_,observations) <- foldM step (root,projected,[observation]) edits
  pure (result,observations)
  where
    step (value,previous,observations) (reason,action) = do
      changed <- execStateT action value
      current <- record binding changed
      pure (changed,current,observations ++ [Observation Authored reason previous current])

project :: TargetBinding root -> StoredSnapshot -> Either EvolutionFailure (Typed.KnowledgeBase root)
project (TargetBinding mappings shape decode _ decodeRecipe _) (StoredSnapshot residual collections recipes) = do
  fields <- recordFields shape
  validateMappings fields mappings
  let collectionFields = map snd mappings
      residualFields = [(name,field) | (name,field) <- fields, name `notElem` collectionFields]
  unless (sort (map fst residual) == sort (map fst residualFields))
    (failure "Residual fields do not match target; add, remove or rename them explicitly")
  unless (all (`elem` map fst mappings) (map fst collections) && unique (map fst collections))
    (failure "Stored collections not declared in target; remove or rename them explicitly")
  values <- traverse (\(name,expected) -> do
    value <- required name residual
    checkedValue expected value >>= \encoded -> pure (Key.fromText name,encoded)) residualFields
  populated <- traverse (\(logical,field) -> do
    expected <- required field fields
    element <- case expected of StoredList inner -> Right inner; _ -> failure "Target collection must be a list"
    let members = maybe [] id (lookup logical collections)
    checkIds members
    encoded <- traverse (\(Fact identity value) -> do
      actual <- envelopeId value
      unless (identity == actual) (failure "Fact envelope identity differs from membership")
      checkedValue element value) members
    pure (Key.fromText field,toJSON encoded)) mappings
  root <- decode (RecordedValue (canonicalShape shape) (Object (Keys.fromList (values ++ populated))))
  checkIds recipes
  states <- traverse (\(Fact identity value) -> Fact identity <$> recipeContext identity (decodeRecipe value)) recipes
  pure (Typed.KnowledgeBase root states)

record :: TargetBinding root -> Typed.KnowledgeBase root -> Either EvolutionFailure StoredSnapshot
record (TargetBinding mappings _ _ encode _ encodeRecipe) (Typed.KnowledgeBase root recipes) = do
  RecordedValue shape encoded <- encode root
  fields <- recordFields shape
  validateMappings fields mappings
  values <- case encoded of Object object -> Right (Keys.toList object); _ -> failure "Target Root must encode a record"
  unless (sort (map (Key.toText . fst) values) == sort (map fst fields)) (failure "Target Root encoding differs from its shape")
  residual <- traverse (\(name,field) -> do
    value <- required (Key.fromText name) values
    pure (name,RecordedValue field value)) [(name,field) | (name,field) <- fields, name `notElem` map snd mappings]
  collections <- traverse (\(logical,field) -> do
    fieldShape <- required field fields
    value <- required (Key.fromText field) values
    members <- case (fieldShape,value) of
      (StoredList element,Array entries) -> traverse (\entry -> do
        let recorded = RecordedValue element entry
        identity <- envelopeId recorded
        pure (Fact identity recorded)) (toList entries)
      _ -> failure "Target collection encoding is not a list"
    checkIds members
    pure (logical,members)) mappings
  checkIds recipes
  states <- traverse (\(Fact identity state) -> Fact identity <$> recipeContext identity (encodeRecipe state)) recipes
  pure (StoredSnapshot residual collections states)

checkedValue :: StoredShape -> RecordedValue -> Either EvolutionFailure Value
checkedValue expected (RecordedValue actual value)
  | canonicalShape expected == canonicalShape actual = Right value
  | otherwise = failure "Stored value shape differs from target shape"

recordFields :: StoredShape -> Either EvolutionFailure [(Text,StoredShape)]
recordFields shape = case canonicalShape shape of
  StoredRecord fields | unique (map fst fields) -> Right fields
  _ -> failure "Target Root must be a record with unique fields"

validateMappings :: [(Text,StoredShape)] -> [(Text,Text)] -> Either EvolutionFailure ()
validateMappings fields mappings = unless
  (unique (map fst mappings) && unique (map snd mappings) && all (`elem` map fst fields) (map snd mappings))
  (failure "Invalid target collection bindings")

required :: (Eq key) => key -> [(key,value)] -> Either EvolutionFailure value
required key entries = case [value | (name,value) <- entries, name == key] of
  [value] -> Right value
  _ -> failure "Missing or duplicate stored field"

unique :: Eq a => [a] -> Bool
unique values = length values == length (nub values)

checkIds :: [Fact a] -> Either EvolutionFailure ()
checkIds values = do
  let ids = [identity | Fact identity _ <- values]
  unless (unique ids) (failure "Duplicate identities")
  mapM_ (\(FactId name) -> either failure (const (Right ())) (parseFactId name)) ids

envelopeId :: RecordedValue -> Either EvolutionFailure FactId
envelopeId (RecordedValue shape (Object object))
  | StoredRecord [("id",StoredText),("value",_)] <- canonicalShape shape
  , values <- Keys.toList object
  , sort (map fst values) == ["id","value"]
  , Just (String name) <- lookup "id" values = either failure Right (parseFactId name)
envelopeId _ = failure "Invalid fact envelope"

recipeContext :: FactId -> Either EvolutionFailure a -> Either EvolutionFailure a
recipeContext (FactId name) = either (\(EvolutionFailure diagnostics) -> Left (EvolutionFailure
  [Diagnostic level diagnosticCode ("Recipe " <> name <> ": " <> diagnosticMessage <>
    ". If the stored state cannot decode under the current type, use migrateRecipe or retireRecipe.") diagnosticLocation
  | Diagnostic level diagnosticCode diagnosticMessage diagnosticLocation <- diagnostics])) Right
