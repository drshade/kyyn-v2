module RecipeTests (main) where

import Control.Monad (unless)
import Kyyn.Recipe
import Kyyn.Types.Evidence (EvidenceRef(..))

main :: IO ()
main = do
  let a = EvidenceScope "files" "one" "f1"
      b = EvidenceScope "files" "two" "f2"
      c = EvidenceScope "other" "empty" "f3"
      ident = EvidenceId "same"
      gone = EvidenceId "gone"
      batches = [PendingEvidence a [New ident, Removed gone, Updated ident],
        Reconciliation b [ident], PendingEvidence c [], Reconciliation c []]
      check label ok = unless ok (fail label)
  check "pending items preserve scope and order" (pendingItems batches == [(a,ident),(a,ident),(b,ident)])
  check "only explicit removals" (removedItems batches == [(a,gone)])
  check "all scopes including empty batches" (scopes batches == [a,b,c,c])
  check "explicit whole-batch declaration" (acknowledgeAll (RecipeInput (RecipeId "sync") () batches)
    == Curation (RecipeId "sync") (map EntireBatch [a,b,c,c]))
  check "opaque citation without invented links" (cite b ident == EvidenceRef "files" "two" "same" [])
  check "handled items group interleaved scopes in first-seen order"
    (acknowledgeItems [(b,ident),(a,gone),(b,gone),(a,ident)]
      == [IndividualRecords b [ident,gone], IndividualRecords a [gone,ident]])
  check "grouping preserves duplicate items for host validation"
    (acknowledgeItems [(a,ident),(a,ident)] == [IndividualRecords a [ident,ident]])
  let newer = EvidenceScope "files" "one" "f2"
  check "different fetch scopes stay distinct"
    (acknowledgeItems [(a,ident),(newer,ident)]
      == [IndividualRecords a [ident], IndividualRecords newer [ident]])
  check "empty handled input" (acknowledgeItems [] == [])
  check "empty input" (null (pendingItems []) && null (removedItems []) && null (scopes [])
    && acknowledgeAll (RecipeInput (RecipeId "sync") () []) == Curation (RecipeId "sync") [])
