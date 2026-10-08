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
data Proposal = Proposal [ProposedStep] deriving (Eq, Show)

-- Explicit fixture codecs exercise the agentic transport independently of code generation.
instance A.Contract EvidenceRef where
  contract = A.record "Evidence citation" $ EvidenceRef
    <$> stringField "producer" producer <*> stringField "connector" instanceName
    <*> stringField "source" source
    <*> A.required "externalReferences" "External references" externalReferences

stringField name getter = A.required name "" getter

instance A.Contract Proposal where
  contract = A.record "Proposal" $ Proposal
    <$> A.required "steps" "Ordered steps" (\(Proposal steps) -> steps)

instance A.Contract a => A.Contract (FactEdit a) where
  contract = A.sumOf "Fact edit"
    [ A.constructor "Append" "Add a new ID" isAppend
        (Append <$> (Fact <$> ident <*> payload))
    , A.constructor "Replace" "Replace an existing payload" isReplace
        (Replace <$> ident <*> payload)
    , A.constructor "Remove" "Remove an existing ID" isRemove (Remove <$> ident)
    ]
    where
      ident = FactId <$> A.required "id" "Fact ID" identifier
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
    ProposedStep <$> (Rationale <$> A.required "reason" "Explanation" reason
      <*> A.required "citations" "Evidence citations" citations)
      <*> A.required "edits" "Ordered edits" edits
    where
      reason (ProposedStep (Rationale text _) _) = text
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
      [("todos", J.encodeWith (J.listCodec (factCodec J.textCodec)) values),
       ("flags", J.encodeWith (J.listCodec (factCodec J.boolCodec)) bools)]
    factCodec codec = J.Codec (\(Fact (FactId key) value) -> J.record
      [("id",J.encodeWith J.textCodec key),("value",J.encodeWith codec value)])
      (const (Left "Fixture fact is output only"))

before :: Root
before = Root [Fact (FactId "old") "old", Fact (FactId "remove") "obsolete"] []
