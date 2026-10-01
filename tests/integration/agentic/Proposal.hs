{-# LANGUAGE OverloadedStrings #-}
module Proposal where

import qualified Agentic as A
import qualified Data.Text as T
import Kyyn.Evolution
import Kyyn.Types.Fact (Fact(..), FactId(..))
import qualified Kyyn.Evolution.Internal as E
import Kyyn.Edit.Internal (Collection(..))
import qualified Kyyn.Runtime.Json as J

-- Fixture bindings: production generation is deliberately not claimed here.
data Root = Root [Fact T.Text] [Fact Bool] deriving (Eq, Show)
data FactEdit a = Append (Fact a) | Replace FactId a | Remove FactId deriving (Eq, Show)
data RootEdit = Todos (FactEdit T.Text) | Flags (FactEdit Bool) deriving (Eq, Show)
data ProposedStep = ProposedStep Rationale [RootEdit] deriving (Eq, Show)
data Proposal = Proposal [ProposedStep] Curation deriving (Eq, Show)

-- Explicit fixture codecs stand in for the future compiler-generated bindings.
instance A.Contract EvidenceRef where
  contract = A.record "Evidence citation" $ EvidenceRef
    <$> stringField "producer" producer <*> stringField "connector" instanceName
    <*> stringField "source" source
    <*> (map T.unpack <$> A.required "references" "References" (map T.pack . references))

stringField name getter = T.unpack <$> A.required name "" (T.pack . getter)

instance A.Contract EvidenceScope where
  contract = A.record "Evidence scope" $ EvidenceScope
    <$> stringField "plugin" (\(EvidenceScope p _ _) -> p)
    <*> stringField "instance" (\(EvidenceScope _ i _) -> i)
    <*> stringField "fetch" (\(EvidenceScope _ _ f) -> f)

instance A.Contract Acknowledgement where
  contract = A.sumOf "Handled evidence"
    [A.constructor "EntireBatch" "All evidence" entire
       (EntireBatch <$> A.required "scope" "Capture" scope),
     A.constructor "IndividualRecords" "Selected items" individual
       (IndividualRecords <$> A.required "scope" "Capture" scope
         <*> (map (EvidenceId . T.unpack) <$> A.required "ids" "Items" ids))]
    where
      entire (EntireBatch _) = True
      entire _ = False
      individual (IndividualRecords _ _) = True
      individual _ = False
      scope (EntireBatch s) = s
      scope (IndividualRecords s _) = s
      ids (IndividualRecords _ keys) = [T.pack key | EvidenceId key <- keys]
      ids _ = []

instance A.Contract Curation where
  contract = A.record "Curation" $ Curation
    <$> (RecipeId <$> stringField "recipe" (\(Curation (RecipeId name) _) -> name))
    <*> A.required "handled" "Acknowledgements" (\(Curation _ handled) -> handled)

instance A.Contract Proposal where
  contract = A.record "Proposal" $ Proposal
    <$> A.required "steps" "Ordered steps" (\(Proposal steps _) -> steps)
    <*> A.required "curation" "Declared curation" (\(Proposal _ curation) -> curation)

instance A.Contract a => A.Contract (FactEdit a) where
  contract = A.sumOf "Fact edit"
    [ A.constructor "Append" "Add a new ID" isAppend
        (Append <$> (Fact <$> ident <*> payload))
    , A.constructor "Replace" "Replace an existing payload" isReplace
        (Replace <$> ident <*> payload)
    , A.constructor "Remove" "Remove an existing ID" isRemove (Remove <$> ident)
    ]
    where
      ident = FactId . T.unpack <$> A.required "id" "Fact ID" (T.pack . identifier)
      payload = A.required "value" "New payload" value
      identifier (Append (Fact (FactId key) _)) = key
      identifier (Replace (FactId key) _) = key
      identifier (Remove (FactId key)) = key
      value (Append (Fact _ v)) = v
      value (Replace _ v) = v
      value (Remove _) = error "Remove has no payload"
      isAppend (Append _) = True
      isAppend _ = False
      isReplace (Replace _ _) = True
      isReplace _ = False
      isRemove (Remove _) = True
      isRemove _ = False

instance A.Contract RootEdit where
  contract = A.sumOf "Root collections"
    [ A.constructor "Todos" "Todo facts" isTodos
        (Todos <$> A.required "edit" "Operation" todoEdit)
    , A.constructor "Flags" "Boolean facts" isFlags
        (Flags <$> A.required "edit" "Operation" flagEdit)
    ]
    where
      isTodos (Todos _) = True
      isTodos _ = False
      isFlags (Flags _) = True
      isFlags _ = False
      todoEdit (Todos e) = e
      todoEdit _ = error "Not Todos"
      flagEdit (Flags e) = e
      flagEdit _ = error "Not Flags"

instance A.Contract ProposedStep where
  contract = A.record "Annotated edits" $
    ProposedStep <$> (Rationale . T.unpack <$> A.required "reason" "Explanation" reason
      <*> A.required "citations" "Evidence citations" citations)
      <*> A.required "edits" "Ordered edits" edits
    where
      reason (ProposedStep (Rationale text _) _) = T.pack text
      edits (ProposedStep _ values) = values
      citations (ProposedStep (Rationale _ evidence) _) = evidence

todos :: Collection Root T.Text
todos = Collection "todos" (\f (Root values flags) -> (\new -> Root new flags) <$> f values)

flags :: Collection Root Bool
flags = Collection "flags" (\f (Root values bools) -> Root values <$> f bools)

applyFact :: FactEdit a -> CollectionEdit a ()
applyFact (Append value) = append value
applyFact (Replace key value) = update key (put value)
applyFact (Remove key) = remove key

applyRoot :: RootEdit -> Edit Root ()
applyRoot (Todos value) = within todos (applyFact value)
applyRoot (Flags value) = within flags (applyFact value)

proposalEvolution :: [ProposedStep] -> Evolution Root Root
proposalEvolution = foldr ((>=>) . step) identityEvolution
  where
    step (ProposedStep why edits) = E.edit binding why (mapM_ applyRoot edits)
    binding = E.RootBinding "fixture-root-v1" (J.encodeWith rootCodec)

rootCodec :: J.Codec Root
rootCodec = J.Codec encode (const (Left "Fixture root is output only"))
  where
    encode (Root values bools) = J.record
      [("todos", J.encodeWith (J.listCodec (factCodec (J.Codec (J.encodeWith J.stringCodec . T.unpack)
         (fmap T.pack . J.decodeWith J.stringCodec)))) values),
       ("flags", J.encodeWith (J.listCodec (factCodec J.boolCodec)) bools)]
    factCodec codec = J.Codec (\(Fact (FactId key) value) -> J.record
      [("id",J.encodeWith J.stringCodec key),("value",J.encodeWith codec value)])
      (const (Left "Fixture fact is output only"))

before :: Root
before = Root [Fact (FactId "old") "old", Fact (FactId "remove") "obsolete"] []
