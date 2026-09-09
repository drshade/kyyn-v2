{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Result
  ( Response(..), Outcome(..), exitStatus, responseJson, diagnosticText
  , success, refusal, operationalFailure, interruption, previewRefusal
  , rootResult, workspaceResult, summariesResult, inspectionResult, candidateResult
  , validationResult, acceptanceResult, recoveryResult, stateResult
  ) where

import Data.Aeson (Value(..), object, (.=), encode)
import qualified Data.ByteString.Lazy as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract (describeRootContract)
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport
import Kyyn.Domain.Failure
import Kyyn.Domain.Git (GitRevision, revisionName, LocalBranch(..))
import Kyyn.Domain.Path (relativeName)
import Kyyn.Domain.Publication
import Kyyn.Domain.Root (Root(..), CheckedValue(..))
import Kyyn.Domain.Workspace (EvolutionState)
import Kyyn.Types.Evolution (Rationale(..), EvolutionFailure(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Fact (FactId(..))

data Outcome = Succeeded | Refused | Failed | Incomplete | Interrupted deriving (Eq, Show)
data Response = Response Outcome Value [String] [Diagnostic] deriving (Eq, Show)

exitStatus :: Response -> Int
exitStatus (Response outcome _ _ _) = case outcome of
  Succeeded -> 0
  Refused -> 1
  Failed -> 3
  Incomplete -> 4
  Interrupted -> 130

responseJson :: Response -> Value
responseJson (Response outcome result _ diagnostics) = object
  ["outcome" .= show outcome, "result" .= result, "diagnostics" .= map diagnosticJson diagnostics]

success :: Value -> [String] -> Response
success result text = Response Succeeded result text []

refusal :: [Diagnostic] -> Response
refusal = Response Refused Null []

operationalFailure :: OperationalFailure -> Response
operationalFailure failure = Response Failed Null [] [case failure of
  RuntimeUnavailable (ProcessDiagnostic operation message) -> errorDiagnostic "runtime.unavailable" (show operation ++ ": " ++ message)
  StorageUnavailable (StorageDiagnostic operation path message) -> errorDiagnostic "storage.unavailable" (show operation ++ " " ++ path ++ ": " ++ message)
  CompilerUnavailable message -> errorDiagnostic "compiler.unavailable" message
  GitUnavailable message -> errorDiagnostic "git.unavailable" message]

interruption :: Maybe EvolutionId -> Response
interruption identity = Response Interrupted Null [] [errorDiagnostic "execution.interrupted"
  ("Operation interrupted." ++ maybe "" (\value ->
    " Acceptance may already have occurred. Inspect evolution " ++ evolutionIdName value ++
    "; use kyyn --kb PATH evolution recover " ++ evolutionIdName value ++ " if accepted.") identity)]

previewRefusal :: PreviewRejection -> Response
previewRefusal (ProposedCodeRejected diagnostics) = refusal diagnostics
previewRefusal (EvolutionRejected (EvolutionFailure diagnostics)) = refusal diagnostics

rootResult :: GitRevision -> Root -> CheckedValue -> Response
rootResult revision (Root schema _ _) (CheckedValue _ value) = success
  (object ["revision" .= revisionName revision, "schema" .= describeRootContract schema, "value" .= value])
  ["Root at " ++ revisionName revision, jsonText value]

workspaceResult :: EvolutionWorkspace -> FilePath -> Response
workspaceResult (EvolutionWorkspace _ identity) path = success
  (object ["id" .= evolutionIdName identity, "path" .= path, "state" .= ("Draft" :: String)])
  ["Created draft " ++ evolutionIdName identity, path]

summariesResult :: [EvolutionSummary] -> Response
summariesResult summaries = success (object ["evolutions" .= map summaryJson summaries])
  (if null summaries then ["No evolutions."] else map summaryText summaries)

inspectionResult :: GitRevision -> (EvolutionSummary, Maybe EvolutionReport) -> Response
inspectionResult revision (summary, report) = success
  (object ["revision" .= revisionName revision, "evolution" .= summaryJson summary, "report" .= fmap reportJson report])
  ([summaryText summary, "Inspected at " ++ revisionName revision] ++ maybe ["No saved report."] reportText report)

candidateResult :: Candidate Root -> Response
candidateResult (Candidate (EvolutionContext _ identity (Before revision _) _) report (Root schema _ _)) = success
  (object ["id" .= evolutionIdName identity, "beforeRevision" .= revisionName revision,
    "schema" .= describeRootContract schema, "report" .= reportJson report])
  (["Saved candidate for " ++ evolutionIdName identity] ++ reportText report)

validationResult :: String -> ValidationReport -> Bool -> Response
validationResult subject (ValidationReport diagnostics) passed = Response
  (if passed then Succeeded else Refused)
  (object ["subject" .= subject, "passed" .= passed])
  [subject ++ if passed then ": checks passed." else ": checks failed."] diagnostics

stateResult :: EvolutionId -> EvolutionState -> Response
stateResult identity state = success
  (object ["id" .= evolutionIdName identity, "state" .= show state])
  [evolutionIdName identity ++ " " ++ show state]

acceptanceResult :: AcceptanceResult -> Response
acceptanceResult result = case result of
  NotAccepted problem -> refusal (case problem of
    BaseMismatch expected actual -> [errorDiagnostic "acceptance.base-mismatch"
      ("Before is " ++ revisionName expected ++ "; current head is " ++ maybe "absent" revisionName actual ++
       ". Update Before and evaluate/check the evolution again.")]
    NotReady state -> [errorDiagnostic "acceptance.not-ready" ("Evolution is " ++ show state ++ "; mark it ready before accepting.")]
    CheckoutMismatch (LocalBranch selected) actual -> [errorDiagnostic "acceptance.checkout-mismatch"
      ("Expected checked-out branch " ++ selected ++ "; found " ++ maybe "detached HEAD" (\(LocalBranch name) -> name) actual)]
    WorkspaceChanged identity -> [errorDiagnostic "acceptance.workspace-changed"
      ("Inputs changed for " ++ evolutionIdName identity ++ "; evaluate it again.")]
    OverlappingEdits paths -> [errorDiagnostic "acceptance.overlapping-edits"
      ("Resolve local edits before accepting: " ++ unwords (map relativeName paths))]
    InvalidMaterial diagnostics -> diagnostics)
  AcceptedCommit revision outcome -> checkoutResult "Accepted" revision revision outcome
  AlreadyAccepted revision diagnostic -> Response Incomplete
    (object ["accepted" .= True, "revision" .= revisionName revision, "checkoutVerified" .= False])
    ["Already accepted at " ++ revisionName revision ++ "; inspect the checkout or use evolution recover."] [diagnostic]

recoveryResult :: Maybe CheckoutRecovery -> Response
recoveryResult Nothing = refusal [errorDiagnostic "evolution.not-accepted" "No confirmed acceptance was found; there is no checkout to recover for this evolution."]
recoveryResult (Just (CheckoutRecovery accepted current outcome)) = checkoutResult "Recovered" accepted current outcome

checkoutResult :: String -> GitRevision -> GitRevision -> WorkingTreeOutcome -> Response
checkoutResult label accepted current outcome = Response
  (case outcome of WorkingTreeUpdated -> Succeeded; WorkingTreeUpdateIncomplete _ -> Incomplete)
  (object ["accepted" .= True, "acceptingCommit" .= revisionName accepted, "checkoutRevision" .= revisionName current,
    "checkoutUpdated" .= (outcome == WorkingTreeUpdated)])
  [label ++ " at " ++ revisionName accepted ++ case outcome of
    WorkingTreeUpdated -> "; checkout synchronized."
    WorkingTreeUpdateIncomplete _ -> "; checkout incomplete. Use evolution recover after resolving the reported problem."]
  (case outcome of WorkingTreeUpdated -> []; WorkingTreeUpdateIncomplete diagnostics -> diagnostics)

summaryJson :: EvolutionSummary -> Value
summaryJson (EvolutionSummary (EvolutionWorkspace _ identity) (EvolutionName name) state accepted) = object
  ["id" .= evolutionIdName identity, "name" .= name, "state" .= show state, "acceptingCommit" .= fmap revisionName accepted]

summaryText :: EvolutionSummary -> String
summaryText (EvolutionSummary (EvolutionWorkspace _ identity) (EvolutionName name) state _) =
  evolutionIdName identity ++ "  " ++ show state ++ "  " ++ name

reportJson :: EvolutionReport -> Value
reportJson (EvolutionReport steps) = object ["steps" .= map step steps]
  where
    step (StepReport (Rationale explanation evidence) changes) = object
      ["explanation" .= explanation, "evidence" .= map evidenceJson evidence, "changes" .= map change changes]
    change (FactChange collection (FactId identity) before after) = object
      ["collection" .= collection, "id" .= identity, "before" .= fmap recorded before, "after" .= fmap recorded after]
    recorded (RecordedFact contract value) = object ["schema" .= describeRootContract contract, "value" .= value]
    evidenceJson (EvidenceRef producer connector source references) = object
      ["producer" .= producer, "connector" .= connector, "source" .= source, "references" .= references]

reportText :: EvolutionReport -> [String]
reportText (EvolutionReport steps) = concatMap step steps
  where
    step (StepReport (Rationale explanation evidence) changes) = [explanation]
      ++ ["  Evidence: " ++ source ++ " " ++ unwords references | EvidenceRef _ _ source references <- evidence]
      ++ concatMap change changes
    change (FactChange collection (FactId identity) before after) =
      ["  " ++ collection ++ "/" ++ identity]
      ++ ["    before: " ++ maybe "(absent)" value before, "    after:  " ++ maybe "(absent)" value after]
    value (RecordedFact _ contents) = jsonText contents

diagnosticText :: Diagnostic -> String
diagnosticText (Diagnostic severity code message location) =
  show severity ++ " [" ++ code ++ "] " ++ message ++ maybe "" (\value -> " (" ++ show value ++ ")") location

diagnosticJson :: Diagnostic -> Value
diagnosticJson (Diagnostic severity code message location) = object
  ["severity" .= show severity, "code" .= code, "message" .= message, "location" .= fmap encodeLocation location]
  where
    encodeLocation (FactLocation collection identity field) = object
      ["kind" .= ("fact" :: String), "collection" .= collection, "id" .= identity, "field" .= field]
    encodeLocation (SourceLocation path line column) = object
      ["kind" .= ("source" :: String), "path" .= path, "line" .= line, "column" .= column]
    encodeLocation (ExampleLocation name) = object ["kind" .= ("example" :: String), "name" .= name]

jsonText :: Value -> String
jsonText = Text.unpack . Text.decodeUtf8 . Bytes.toStrict . encode
