{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Result
  ( Response(..), Outcome(..), exitStatus, responseJson, diagnosticText
  , success, refusal, operationalFailure, interruption, previewRefusal, evolutionCheckResult
  , rootResult, workspaceResult, summariesResult, inspectionResult, candidateResult
  , validationResult, checkResult, inspectionCheckResult, acceptanceResult, recoveryResult, stateResult, initializationResult, pluginResult
  ) where

import Data.Aeson (Value(..), object, (.=), encode)
import qualified Data.ByteString.Lazy as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract (describeRootContract)
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport
import Kyyn.Types.Curation
import Kyyn.Types.Evidence (EvidenceId(..))
import Kyyn.Domain.Failure
import Kyyn.Domain.Git (GitRevision, revisionName, LocalBranch(..), Repository(..), TreePath(..), gitUrlText)
import Kyyn.Domain.Plugin (InstalledPlugin(..), PluginOrigin(..), PluginRepository(..), pluginNameText)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (relativeName, scopePath, scopedPath)
import Kyyn.Domain.Publication
import Kyyn.Domain.Root (Root(..), CheckedValue(..))
import Kyyn.Domain.Workspace (EvolutionState)
import Kyyn.Porcelain.Validated (Validated, validatedValue)
import Kyyn.Types.Evolution (Rationale(..), EvolutionFailure(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.KnowledgeBase (Recipe(..))

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

pluginResult :: EvolutionId -> InstalledPlugin -> Response
pluginResult evolution (InstalledPlugin name location (PluginOrigin repository path revision)) =
  let (kind, source) = case repository of
        LocalRepository scope -> ("Local" :: String, scopePath scope)
        RemoteRepository url -> ("Git", gitUrlText url)
      subdirectory = case path of WholeTree -> Nothing; Subtree selected -> Just (relativeName selected)
  in success
    (object ["name" .= pluginNameText name, "location" .= scopePath location,
      "origin" .= object ["repository" .= object ["kind" .= kind, "location" .= source],
        "path" .= subdirectory, "revision" .= revisionName revision]])
    ["Installed plugin " ++ pluginNameText name, "Location: " ++ scopePath location,
      "Source: " ++ source ++ maybe "" (\selected -> " (" ++ selected ++ ")") subdirectory,
      "Revision: " ++ revisionName revision,
      "Guide: kyyn-v2 plugin guide " ++ pluginNameText name ++ " --evolution " ++ evolutionIdName evolution,
      "Configuration: kyyn-v2 plugin connector schema show " ++ pluginNameText name ++ " --evolution " ++ evolutionIdName evolution]

initializationResult :: CheckResult InitializationResult -> Response
initializationResult (Rejected report) = validationResult "Initialization" report False
initializationResult (Passed (InitializedRoot revision (LocalBranch branch) (KnowledgeBase (Repository repository) prefix) checkout) (ValidationReport warnings)) =
  let complete = checkout == WorkingTreeUpdated
      diagnostics = case checkout of WorkingTreeUpdated -> []; WorkingTreeUpdateIncomplete values -> values
      location = case prefix of WholeTree -> scopePath repository; Subtree path -> scopedPath repository path
      rootPath = case prefix of WholeTree -> "root"; Subtree path -> relativeName path ++ "/root"
      tapsPath = case prefix of WholeTree -> "taps.dhall"; Subtree path -> relativeName path ++ "/taps.dhall"
      quote value = "'" ++ concatMap (\c -> if c == '\'' then "'\\''" else [c]) value ++ "'"
  in Response (if complete then Succeeded else Incomplete)
    (object ["revision" .= revisionName revision, "branch" .= branch, "path" .= location, "checkoutSynchronized" .= complete])
    (["Initialized knowledge base at " ++ location, "Committed " ++ revisionName revision ++ " on " ++ branch] ++
      if complete then ["Next, from the KB directory: kyyn-v2 evolution new NAME"] else [])
    (warnings ++ diagnostics ++ if complete then [] else [errorDiagnostic "kb.checkout-incomplete"
      ("The root is committed. Restore its checkout with: git -C " ++ quote (scopePath repository) ++
       " restore --source=" ++ revisionName revision ++ " --staged --worktree -- " ++ quote rootPath ++ " " ++ quote tapsPath ++
       "\nRe-running kb init will refuse the existing root.")])

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
    "; use kyyn-v2 --kb PATH evolution recover " ++ evolutionIdName value ++ " if accepted.") identity)]

previewRefusal :: PreviewRejection -> Response
previewRefusal (ProposedCodeRejected diagnostics) = refusal diagnostics
previewRefusal (EvolutionRejected (EvolutionFailure diagnostics)) = refusal diagnostics

evolutionCheckResult :: EvolutionId
  -> Either PreviewRejection (CheckResult (Candidate (Validated Root))) -> Response
evolutionCheckResult identity result = case result of
  Left rejected ->
    let Response outcome _ messages diagnostics = previewRefusal rejected
        notice = "No new candidate was produced for " ++ name ++
          ". Any earlier saved candidate is unchanged; evolution show " ++ name ++ " will still show that earlier result."
    in Response outcome (object ["id" .= name, "candidateSaved" .= False])
      (notice : messages) diagnostics
  Right (Rejected (ValidationReport diagnostics)) -> Response Refused
    (object ["id" .= name, "candidateSaved" .= True, "passed" .= False])
    ["Saved candidate " ++ name ++ ": checks failed. Inspect it with evolution show " ++ name ++ "."] diagnostics
  Right (Passed checked (ValidationReport diagnostics)) ->
    let Response outcome value messages _ = candidateResult (fmap validatedValue checked)
    in Response outcome value (messages ++ ["Checks passed."]) diagnostics
  where name = evolutionIdName identity

rootResult :: GitRevision -> Root -> CheckedValue -> Response
rootResult revision (Root schema _ _ _ _) (CheckedValue _ value) = success
  (object ["revision" .= revisionName revision, "schema" .= describeRootContract schema, "value" .= value])
  ["Root at " ++ revisionName revision, jsonText value]

workspaceResult :: EvolutionWorkspace -> GitRevision -> FilePath -> Response
workspaceResult (EvolutionWorkspace _ identity) revision path = success
  (object ["id" .= evolutionIdName identity, "path" .= path, "beforeRevision" .= revisionName revision, "state" .= ("Draft" :: String)])
  ["Created draft " ++ evolutionIdName identity, "Before " ++ revisionName revision, path]

summariesResult :: [EvolutionSummary] -> Response
summariesResult summaries = success (object ["evolutions" .= map summaryJson summaries])
  (if null summaries then ["No evolutions."] else map summaryText summaries)

inspectionResult :: GitRevision -> (EvolutionSummary, Maybe EvolutionReport) -> Response
inspectionResult revision (summary, report) = success
  (object ["revision" .= revisionName revision, "evolution" .= summaryJson summary, "report" .= fmap reportJson report])
  ([summaryText summary, "Inspected at " ++ revisionName revision] ++ maybe ["No saved report."] reportText report)

candidateResult :: Candidate Root -> Response
candidateResult (Candidate (EvolutionContext _ identity (Before revision _) _) report (Root schema _ _ _ _)) = success
  (object ["id" .= evolutionIdName identity, "beforeRevision" .= revisionName revision,
    "schema" .= describeRootContract schema, "report" .= reportJson report])
  (["Saved candidate for " ++ evolutionIdName identity] ++ reportText report)

validationResult :: String -> ValidationReport -> Bool -> Response
validationResult subject (ValidationReport diagnostics) passed = Response
  (if passed then Succeeded else Refused)
  (object ["subject" .= subject, "passed" .= passed])
  [subject ++ if passed then ": checks passed." else ": checks failed."] diagnostics

checkResult :: String -> CheckResult a -> Response
checkResult subject result = case result of
  Rejected report -> validationResult subject report False
  Passed _ report -> validationResult subject report True

inspectionCheckResult :: GitRevision -> CheckResult (Validated Root, CheckedValue) -> Response
inspectionCheckResult revision result = case result of
  Rejected report -> validationResult ("Root at " ++ revisionName revision) report False
  Passed (root,facts) (ValidationReport warnings) -> case rootResult revision (validatedValue root) facts of
    Response outcome value text _ -> Response outcome value text warnings

stateResult :: EvolutionId -> EvolutionState -> Response
stateResult identity state = success
  (object ["id" .= evolutionIdName identity, "state" .= show state])
  [evolutionIdName identity ++ " " ++ show state]

acceptanceResult :: AcceptanceResult -> Response
acceptanceResult result = case result of
  NotAccepted problem -> refusal (case problem of
    BaseMismatch expected actual -> [errorDiagnostic "acceptance.base-mismatch"
      ("Before is " ++ revisionName expected ++ "; current head is " ++ maybe "absent" revisionName actual ++
       ". Update Before and check the evolution again.")]
    NotReady state -> [errorDiagnostic "acceptance.not-ready" ("Evolution is " ++ show state ++ "; mark it ready before accepting.")]
    CheckoutMismatch (LocalBranch selected) actual -> [errorDiagnostic "acceptance.checkout-mismatch"
      ("Expected checked-out branch " ++ selected ++ "; found " ++ maybe "detached HEAD" (\(LocalBranch name) -> name) actual)]
    WorkspaceChanged identity -> [errorDiagnostic "acceptance.workspace-changed"
      ("Inputs changed for " ++ evolutionIdName identity ++ "; check it again.")]
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
reportJson (EvolutionReport plugins steps curation) = object
  ["steps" .= map step steps,"curation" .= fmap declaration curation,
   "plugins" .= [object ["name" .= pluginNameText name, "before" .= fmap originJson old,
      "after" .= fmap originJson new, "files" .= map relativeName paths] | PluginChange name old new paths <- plugins]]
  where
    declaration (Curation (RecipeId recipe) handled) = object
      ["recipe" .= recipe,"handled" .= map acknowledgement handled]
    scope (EvidenceScope plugin instanceName fetch) = object
      ["plugin" .= plugin,"instance" .= instanceName,"fetch" .= fetch]
    acknowledgement (EntireBatch selected) = object
      ["kind" .= ("EntireBatch" :: String),"scope" .= scope selected]
    acknowledgement (IndividualRecords selected ids) = object
      ["kind" .= ("IndividualRecords" :: String),"scope" .= scope selected,"ids" .= [item | EvidenceId item <- ids]]
    step (StepReport (Rationale explanation evidence) changes) = object
      ["explanation" .= explanation, "evidence" .= map evidenceJson evidence, "changes" .= map change changes]
    change (FactChange collection (FactId identity) before after) = object
      ["kind" .= ("Fact" :: String), "collection" .= collection, "id" .= identity, "before" .= fmap recorded before, "after" .= fmap recorded after]
    change (RecipeChange (FactId identity) before after) = object
      ["kind" .= ("Recipe" :: String), "id" .= identity, "before" .= fmap recipeJson before, "after" .= fmap recipeJson after]
    recipeJson (Recipe instructions) = object ["instructions" .= instructions]
    recorded (RecordedFact contract value) = object ["schema" .= describeRootContract contract, "value" .= value]
    evidenceJson (EvidenceRef producer connector source references) = object
      ["producer" .= producer, "instance" .= connector, "source" .= source, "references" .= references]

reportText :: EvolutionReport -> [String]
reportText (EvolutionReport plugins steps curation) = concatMap pluginLines plugins ++ concatMap step steps ++ maybe [] declaration curation
  where
    pluginLines (PluginChange name old new paths) =
      ["Plugin " ++ pluginNameText name ++ ": " ++ revision old ++ " → " ++ revision new]
      ++ ["  before source: " ++ maybe "(absent)" originText old, "  after source:  " ++ maybe "(absent)" originText new]
      ++ ["  changed: " ++ relativeName path | path <- paths]
    revision = maybe "(absent)" (\(PluginOrigin _ _ selected) -> take 8 (revisionName selected))
    declaration (Curation (RecipeId recipe) handled) = ("Recipe: " ++ recipe) : map acknowledgement handled
    scope (EvidenceScope plugin instanceName fetch) = plugin ++ "/" ++ instanceName ++ " at fetch " ++ fetch
    acknowledgement (EntireBatch selected) = "  Handled entire batch: " ++ scope selected
    acknowledgement (IndividualRecords selected ids) = "  Handled records: " ++ scope selected
      ++ " [" ++ unwords [item | EvidenceId item <- ids] ++ "]"
    step (StepReport (Rationale explanation evidence) changes) = [explanation]
      ++ ["  Declared citations:" | not (null evidence)]
      ++ ["    " ++ source ++ " " ++ unwords references | EvidenceRef _ _ source references <- evidence]
      ++ concatMap change changes
    change (FactChange collection (FactId identity) before after) =
      ["  " ++ collection ++ "/" ++ identity]
      ++ ["    before: " ++ maybe "(absent)" value before, "    after:  " ++ maybe "(absent)" value after]
    change (RecipeChange (FactId identity) before after) =
      ["  Recipe: " ++ identity,
       "    before: " ++ maybe "(absent)" recipeInstructions before,
       "    after:  " ++ maybe "(absent)" recipeInstructions after]
    value (RecordedFact _ contents) = jsonText contents

originJson :: PluginOrigin -> Value
originJson (PluginOrigin repository path revision) = object
  ["source" .= originRepository repository,"path" .= (case path of WholeTree -> Nothing; Subtree p -> Just (relativeName p)),
   "revision" .= revisionName revision]

originText :: PluginOrigin -> String
originText (PluginOrigin repository path _) = originRepository repository ++ case path of
  WholeTree -> ""
  Subtree p -> " (" ++ relativeName p ++ ")"

originRepository :: PluginRepository -> String
originRepository (LocalRepository scope) = scopePath scope
originRepository (RemoteRepository url) = gitUrlText url

diagnosticText :: Diagnostic -> String
diagnosticText (Diagnostic severity code message location) =
  show severity ++ " [" ++ code ++ "] " ++ message ++ maybe "" (\value -> " (" ++ locationText value ++ ")") location
  where
    locationText (FactLocation collection identity field) = collection ++ "/" ++ identity ++ maybe "" ('.' :) field
    locationText (SourceLocation path line column) = path ++ ":" ++ show line ++ ":" ++ show column
    locationText (ExampleLocation name) = "example " ++ name

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
