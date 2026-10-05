-- Pure curation acknowledgement/pending calculations and malformed declaration
-- refusals; no evidence acquisition, guest runtime or Git publication.

module Main (main) where

import Control.Monad (unless)
import Data.Either (isLeft)
import Kyyn.Domain.Contract (ContractId, checkContract, contractId)
import Kyyn.Domain.Curation
import Kyyn.Domain.DataType (DataType(StringType))
import Kyyn.Domain.Evidence
import Kyyn.Domain.Plugin (PackageIdentity(..), pluginName)
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))

assert :: String -> Bool -> IO ()
assert label result = unless result (fail label)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

recipe, otherRecipe :: RecipeId
recipe = RecipeId "todos"
otherRecipe = RecipeId "prices"

producer, otherProducer :: EvidenceProducer
producer = EvidenceProducer (PackageIdentity "source") contract
otherProducer = EvidenceProducer (PackageIdentity "changed-source") contract

contract :: ContractId
contract = contractId (either (error . show) id (checkContract StringType (SchemaMetadata [] [] [])))

instanceA, instanceB :: ConnectorInstanceRef
instanceA = ConnectorInstanceRef (either error id (pluginName "files")) "a"
instanceB = ConnectorInstanceRef (either error id (pluginName "files")) "b"

capture :: ConnectorInstanceRef -> EvidenceProducer -> String -> [(String,String)] -> EvidenceCapture
capture instanceRef source fetch entries = EvidenceCapture
  (EvidenceSnapshotRef instanceRef source (FetchId fetch))
  [(EvidenceId key, EvidenceFingerprint token) | (key,token) <- entries]

at :: String -> [(String,String)] -> EvidenceCapture
at = capture instanceA producer

expect :: String -> RecipeId -> CurationRegister -> EvidenceCapture -> [(String,ChangeKind)] -> IO ()
expect label selected register current expected = do
  PendingEvidence scope actual <- right (pendingEvidence selected register current)
  let EvidenceCapture original _ = current
  assert (label ++ " scope") (scope == original)
  assert label (actual == [(EvidenceId key,kind) | (key,kind) <- expected])

main :: IO ()
main = do
  let empty = emptyCurationRegister
      original = at "f1" [("milk","v1"),("bread","b1")]
      latest = at "f2" [("milk","v2"),("bread","b1")]
  expect "unseen new then updated" recipe empty latest [("milk",New),("bread",New)]
  expect "unseen new then removed" recipe empty (at "f3" []) []
  base <- right (acknowledgeEvidence recipe EntireBatch original empty)
  expect "updates collapse" recipe base latest [("milk",Updated)]
  expect "updated then removed" recipe base (at "f3" []) [("milk",Removed),("bread",Removed)]
  expect "removed and recreated identically" recipe base (at "f4" [("milk","v1"),("bread","b1")]) []
  expect "recreated differently" recipe base latest [("milk",Updated)]
  selected <- right (acknowledgeEvidence recipe (IndividualRecords [EvidenceId "milk"]) original empty)
  expect "selective acknowledgement" recipe selected original [("bread",New)]
  expect "acknowledged new then deleted" recipe selected (at "f3" []) [("milk",Removed)]
  deleted <- right (acknowledgeEvidence recipe (IndividualRecords [EvidenceId "milk"]) (at "fresh-clone-fetch" []) selected)
  expect "deletion acknowledged without old history" recipe deleted (at "another-fetch" []) []
  repeatedDeletion <- right (acknowledgeEvidence recipe (IndividualRecords [EvidenceId "milk"]) (at "another-fetch" []) deleted)
  assert "repeated deletion acknowledgement is idempotent" (repeatedDeletion == deleted)
  expect "reappearance after acknowledged deletion" recipe deleted original [("milk",New),("bread",New)]
  duplicate <- right (acknowledgeEvidence recipe (IndividualRecords [EvidenceId "milk",EvidenceId "milk"]) original selected)
  assert "duplicate acknowledgements idempotent" (duplicate == selected)
  unknown <- right (acknowledgeEvidence recipe (IndividualRecords [EvidenceId "unknown"]) original selected)
  assert "absent unknown acknowledgement is no-op" (unknown == selected)
  expect "recipe isolation" otherRecipe selected original [("milk",New),("bread",New)]
  expect "instance isolation" recipe selected (capture instanceB producer "b1" [("milk","v1")]) [("milk",New)]
  multi <- right (acknowledgeEvidence recipe EntireBatch (capture instanceB producer "b1" [("milk","v1")]) selected)
  expect "another instance retained" recipe multi original [("bread",New)]
  expect "second instance acknowledged" recipe multi (capture instanceB producer "b2" [("milk","v1")]) []
  other <- right (acknowledgeEvidence otherRecipe EntireBatch latest multi)
  expect "another recipe retained" recipe other original [("bread",New)]
  expect "second recipe acknowledged" otherRecipe other latest []
  newer <- right (acknowledgeEvidence recipe (IndividualRecords [EvidenceId "milk"]) latest base)
  olderLast <- right (acknowledgeEvidence recipe EntireBatch original newer)
  expect "older declaration last resurfaces pending" recipe olderLast latest [("milk",Updated)]
  newerLast <- right (acknowledgeEvidence recipe (IndividualRecords [EvidenceId "milk"]) latest olderLast)
  expect "authored order" recipe newerLast latest []
  expect "refresh after prepared acknowledgement" recipe base latest [("milk",Updated)]
  expect "fresh clone no history" recipe base (at "unrelated-new-fetch-id" [("milk","v1")]) [("bread",Removed)]
  let replacement = capture instanceA otherProducer "new-producer" [("milk","v1")]
  let EvidenceCapture replacementScope _ = replacement
  assert "producer mismatch supplies current IDs"
    (pendingEvidence recipe base replacement == Right (Reconciliation replacementScope [EvidenceId "milk"]))
  let noItems = capture instanceA otherProducer "empty-producer" []
      EvidenceCapture emptyScope _ = noItems
  assert "empty replacement still needs reconciliation"
    (pendingEvidence recipe base noItems == Right (Reconciliation emptyScope []))
  assert "individual producer mixing refused"
    (acknowledgeEvidence recipe (IndividualRecords [EvidenceId "milk"]) replacement base == Left CurationProducerChanged)
  reconciled <- right (acknowledgeEvidence recipe EntireBatch replacement base)
  expect "batch producer reconciliation" recipe reconciled replacement []
  emptyReconciled <- right (acknowledgeEvidence recipe EntireBatch noItems base)
  expect "empty batch reconciled" recipe emptyReconciled noItems []
  let malformed = [at "bad" [("milk","v1"),("milk","v2")], at "bad" [("","v1")], at "bad" [("milk","")]]
  mapM_ (\bad -> do
    assert "bad capture refused on read" (isLeft (pendingEvidence recipe empty bad))
    assert "bad capture refused on acknowledgement" (isLeft (acknowledgeEvidence recipe EntireBatch bad empty))) malformed
  putStrLn "Curation core tests passed"
