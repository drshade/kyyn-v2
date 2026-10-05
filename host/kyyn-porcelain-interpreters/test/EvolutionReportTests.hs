-- Structural before/after observations, step chains and identity-based reports
-- through real RootStore/Dhall; malformed guest protocol refusal. No Git/compiler.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..), object, (.=), encode)
import qualified Data.ByteString.Lazy as Lazy
import Effectful (runPureEff)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.EvolutionReport
import qualified Kyyn.Types.Curation as Curation
import Kyyn.Plumbing.Protocol.Curation (curationValue)
import Kyyn.Plumbing.Protocol.Recipes (knowledgeBaseValue)
import qualified Kyyn.Types.KnowledgeBase as KB
import Kyyn.Domain.Root (CheckedValue(..))
import Kyyn.Types.Diagnostic
import Kyyn.Types.Evolution
import Kyyn.Types.Evidence
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.SchemaMetadata
import Kyyn.Porcelain.Capability.EvolutionReport
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Protocol.Evolution (decodeEvolutionReply)

main :: IO ()
main = do
  old <- contract "V1" "Todos" [(Just "title",StringType)] ["todos"]
  renamed <- contract "V1" "Renamed" [(Just "title",StringType)] ["todos"]
  new <- contract "V2" "Todos" [(Just "title",StringType),(Just "done",BoolType)] ["todos"]
  let input = root [fact "a" "First",fact "b" "Second"]
      edited = root [fact "c" "New",fact "a" "Changed"]
      rationale = Rationale "Reconcile todos" [EvidenceRef "graph" "work" "email-id" ["https://example.test/email"]]
      observed c value = ObservedRoot (contractFingerprint (contractId (rootSchema c))) (KB.KnowledgeBase value [])
      step c a d b = StepObservation rationale (observed c a) (observed d b)
      check source value target steps output = fmap (\(KB.KnowledgeBase result _,report) -> (result,report)) $
        runPureEff . runDhallHandling . runRootStore $
          checkEvolutionReport source (KB.KnowledgeBase value []) target (EvolutionObservation (KB.KnowledgeBase output []) steps Nothing)
      changed before after identifier = FactChange "todos" (FactId identifier) before after
      recorded c value = Just (RecordedFact c value)
  (checked, report) <- right (check old input old [step old input old edited] edited)
  assert (checked == CheckedValue (contractId (rootSchema old)) edited) "After was not contract-tagged"
  assert (report == EvolutionReport [] [StepReport rationale
    [changed (recorded old (fact "a" "First")) (recorded old (fact "a" "Changed")) "a",
     changed (recorded old (fact "b" "Second")) Nothing "b",
     changed Nothing (recorded old (fact "c" "New")) "c"]] Nothing) "Wrong identified additions/modifications/deletions"
  (_,EvolutionReport _ reversed _) <- right (check old input old
    [step old input old edited,step old edited old input] input)
  assert (length reversed == 2 && all (\(StepReport r cs) -> r == rationale && length cs == 3) reversed)
    "Cancelling edits or declared evidence disappeared"
  (_,empty) <- right (check old input old [] input)
  assert (empty == EvolutionReport [] [] Nothing) "Identity produced a report"
  let reordered = root [fact "b" "Second",fact "a" "First"]
  (_,reorderReport) <- right (check old input old [step old input old reordered] reordered)
  assert (reorderReport == EvolutionReport [] [StepReport rationale []] Nothing) "Reordering became record edits"
  (_,metadataReport) <- right (check old input renamed [step old input renamed input] input)
  assert (metadataReport == EvolutionReport [] [StepReport rationale
    [changed (recorded old f) (recorded renamed f) identifier | (identifier,f) <- [("a",fact "a" "First"),("b",fact "b" "Second")]]] Nothing)
    "Metadata interpretation change disappeared"
  let migrated = root [object ["id" .= ("a" :: String),"value" .= object ["title" .= ("First" :: String),"done" .= False]]]
  (_,migration) <- right (check old input new [step old input new migrated] migrated)
  assert (migration == EvolutionReport [] [StepReport rationale
    [changed (recorded old (fact "a" "First")) (recorded new (object ["id" .= ("a" :: String),"value" .= object ["title" .= ("First" :: String),"done" .= False]])) "a",
     changed (recorded old (fact "b" "Second")) Nothing "b"]] Nothing) "Migration lost old or new contract/value"
  forM_
    [ check old input old [] edited
    , check old input renamed [] input
    , check old input renamed [step old input renamed input, step renamed input old input,
        step old input renamed input] input
    , check old input renamed [step renamed input renamed input] input
    , check old input old [step old edited old input] input
    , check old input old [step old input old edited,step old input old input] input
    , check old input old [step old input renamed input,step old input old input] input
    , check old input old [step old input old edited] input
    , check old input old [StepObservation rationale (observed old input) (ObservedRoot "unknown" (KB.KnowledgeBase edited []))] edited
    , check old input old [step old input old Null,step old Null old input] input
    , check old input old [step old input renamed (root [fact "a" "First",fact "a" "Second"]),
        step renamed (root [fact "a" "First",fact "a" "Second"]) old input] input
    , check old Null old [] Null
    , check old (root [fact "a" "First",fact "a" "Second"]) old [] (root [fact "a" "First",fact "a" "Second"])
    , check old input new [step old input new input] input
    ] rejected
  two <- contract "Two" "Todos" [(Just "title",StringType)] ["todos","other"]
  let both = object ["todos" .= [fact "a" "First"],"other" .= [fact "a" "Second"]]
      moved = object ["todos" .= ([] :: [Value]),"other" .= [fact "a" "Second"]]
  (_,scoped) <- right (check two both two [step two both two moved] moved)
  assert (scoped == EvolutionReport [] [StepReport rationale [changed (recorded two (fact "a" "First")) Nothing "a"]] Nothing)
    "Fact identity was not scoped to its collection"
  protocolTests
  recipeTests old new input migrated
  putStrLn "Evolution chain, structural values, identity-based reports and protocol rejection checks passed."

recipeTests :: RootContract -> RootContract -> Value -> Value -> IO ()
recipeTests beforeContract afterContract input migrated = do
  let first = KB.OpenAgent "Read todos"
      updated = KB.OpenAgent "Read todos and explain changes"
      entry value = Fact (FactId "syncTodos") value
      before = KB.KnowledgeBase input [entry first]
      after = KB.KnowledgeBase input [entry updated]
      empty = KB.KnowledgeBase input []
      why = Rationale "Refine curation" []
      observed c value = ObservedRoot (contractFingerprint (contractId (rootSchema c))) value
      step c a d b = StepObservation why (observed c a) (observed d b)
      check initial finalContract steps final = runPureEff . runDhallHandling . runRootStore $
        checkEvolutionReport beforeContract initial finalContract (EvolutionObservation final steps Nothing)
      same initial final = check initial beforeContract [step beforeContract initial beforeContract final] final
      expected a b = EvolutionReport [] [StepReport why [RecipeChange (FactId "syncTodos") a b]] Nothing
  (_,added) <- right (same empty before)
  assert (added == expected Nothing (Just first)) "Recipe addition lost identity or instructions"
  (_,edited) <- right (same before after)
  assert (edited == expected (Just first) (Just updated)) "Recipe edit absent from report"
  let closed = KB.ClosedAgent (KB.FlowEntryRef "Tasks.reconcile")
  (_,converted) <- right (same before (KB.KnowledgeBase input [entry closed]))
  assert (converted == expected (Just first) (Just closed)) "Recipe constructor change absent from report"
  (_,removed) <- right (same before empty)
  assert (removed == expected (Just first) Nothing) "Recipe deletion absent from report"
  (_,identity) <- right (check before beforeContract [] before)
  assert (identity == EvolutionReport [] [] Nothing) "Unchanged recipes created changes"
  rejected (check before beforeContract [] after)
  rejected (check before beforeContract [step beforeContract empty beforeContract after] after)
  forM_ [[entry first,entry updated], [Fact (FactId "bad-name") first]] $ \entries -> do
    let invalid = KB.KnowledgeBase input entries
    rejected (same before invalid)
    rejected (check before beforeContract
      [step beforeContract before beforeContract invalid,step beforeContract invalid beforeContract before] before)
  let migratedKb = KB.KnowledgeBase migrated [entry first]
  (_,EvolutionReport _ steps _) <- right (check before afterContract
    [step beforeContract before afterContract migratedKb] migratedKb)
  assert (all (\(StepReport _ changes) -> all domainChange changes) steps)
    "Schema migration falsely changed preserved recipes"
  let changedBoth = KB.KnowledgeBase (root []) [entry updated]
  (_,EvolutionReport _ mixed _) <- right (same before changedBoth)
  assert (case mixed of [StepReport _ changes] -> any domainChange changes && any (not . domainChange) changes; _ -> False)
    "Mixed fact and recipe edits lost a change category"
  where
    domainChange FactChange{} = True
    domainChange RecipeChange{} = False

protocolTests :: IO ()
protocolTests = do
  let decode = decodeEvolutionReply . Lazy.toStrict . encode
      success value = object ["tag" .= ("Succeeded" :: String),"value" .= value]
      empty = KB.KnowledgeBase (root []) []
      wire = knowledgeBaseValue empty
      output = object ["after" .= wire,"steps" .= ([] :: [Value]),"curation" .= object ["tag" .= ("None" :: String)]]
  result <- right (decode (success output))
  assert (result == Right (EvolutionObservation empty [] Nothing)) "Success decoding changed value"
  let declaration = Just (Curation.Curation (Curation.RecipeId "syncTodos")
        [Curation.EntireBatch (Curation.EvidenceScope "files" "documents" "f1"),
         Curation.IndividualRecords (Curation.EvidenceScope "files" "documents" "f2") []])
      declared = object ["after" .= wire,"steps" .= ([] :: [Value]),"curation" .= curationValue declaration]
  acknowledged <- right (decode (success declared))
  assert (acknowledged == Right (EvolutionObservation empty [] declaration)) "Curation protocol lost scope or order"
  let citation = object ["producer" .= ("graph" :: String),"connector" .= ("work" :: String),
        "source" .= ("email-λ" :: String),"references" .= (["https://example.test/λ","/tmp/email"] :: [String])]
      boundary = object ["contract" .= ("contract-id" :: String),"value" .= wire]
      step evidence = object ["before" .= boundary,"after" .= boundary,
        "rationale" .= object ["explanation" .= ("Explain λ" :: String),"evidence" .= [evidence]]]
      withStep value = success (object ["after" .= wire,"steps" .= [value],"curation" .= object ["tag" .= ("None" :: String)]])
  cited <- right (decode (withStep (step citation)))
  assert (cited == Right (EvolutionObservation empty
    [StepObservation (Rationale "Explain λ" [EvidenceRef "graph" "work" "email-λ" ["https://example.test/λ","/tmp/email"]])
      (ObservedRoot "contract-id" empty) (ObservedRoot "contract-id" empty)] Nothing)) "Citation decoding lost identifiers or references"
  rejected (decode (withStep (step (object ["producer" .= ("graph" :: String)]))))
  refusal <- right (decode (object ["tag" .= ("Rejected" :: String),"value" .=
    [object ["severity" .= object ["tag" .= ("Error" :: String)],"code" .= ("refused" :: String),
      "message" .= ("No" :: String),"location" .= object ["tag" .= ("None" :: String)]]]]))
  assert (refusal == Left (EvolutionFailure [Diagnostic Error "refused" "No" Nothing])) "Refusal was not distinguished from malformed protocol"
  forM_ [Null,object [],object ["tag" .= ("Other" :: String),"value" .= output],
    success (object ["after" .= root []]),
    success (object ["after" .= root [],"steps" .= ([] :: [Value]),"extra" .= True]),
    success (object ["after" .= root [],"steps" .= [object []]])] (rejected . decode)

root :: [Value] -> Value
root facts = object ["todos" .= facts]

fact :: String -> String -> Value
fact identifier title = object ["id" .= identifier,"value" .= object ["title" .= title]]

contract :: String -> String -> [(Maybe String,DataType)] -> [String] -> IO RootContract
contract namespace label fields collections = right (checkContract schema metadata >>= checkRootLayout)
  where
    payload = Algebraic (namespace ++ ".Todo") [] [Constructor (namespace ++ ".Todo") fields]
    envelope = Algebraic "Kyyn.Types.Fact.Fact" [payload]
      [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,sdkFactIdType),(Nothing,payload)]]
    schema = Algebraic (namespace ++ ".Root") [] [Constructor (namespace ++ ".Root") [(Just name,ListType envelope) | name <- collections]]
    metadata = SchemaMetadata [RoleDecl "title" label Title] [] [CollectionDecl name name [] | name <- collections]

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

rejected :: Show a => Either e a -> IO ()
rejected (Left _) = pure ()
rejected (Right value) = fail ("Expected rejection, received " ++ show value)

assert :: Bool -> String -> IO ()
assert condition message = unless condition (fail message)
