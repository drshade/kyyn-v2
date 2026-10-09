{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Result
  ( Response(..), Outcome(..), exitStatus, responseJson, diagnosticText
  , success, refusal, operationalFailure, interruption, previewRefusal, evolutionCheckResult
  , rootResult, workspaceResult, summariesResult, inspectionResult, candidateResult
  , validationResult, checkResult, inspectionCheckResult, acceptanceResult, stateResult, initializationResult, pluginResult
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
import Kyyn.Domain.Git (GitRevision, revisionName, LocalBranch(..), Repository(..), TreePath(..), gitUrlText)
import Kyyn.Domain.Plugin (InstalledPlugin(..), PluginOrigin(..), PluginRepository(..), pluginNameText)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (relativeName, scopePath, scopedPath)
import Kyyn.Domain.Publication
import Kyyn.Domain.Root (Root(..), CheckedValue(..))
import Kyyn.Domain.Recipe (StoredRecipe(..))
import Kyyn.Domain.Workspace (EvolutionState(..))
import Kyyn.Porcelain.Validated (Validated, validatedValue)
import Kyyn.Types.Evolution (Rationale(..), EvolutionFailure(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))

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
    "; inspect git status and restore the checkout from Git if acceptance already committed.") identity)]

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
rootResult revision (Root schema _ _ _) (CheckedValue _ value) = success
  (object ["revision" .= revisionName revision, "schema" .= describeRootContract schema, "value" .= value])
  ["Root at " ++ revisionName revision, jsonText value]

workspaceResult :: EvolutionWorkspace -> GitRevision -> FilePath -> Response
workspaceResult (EvolutionWorkspace _ identity) revision path = success
  (object ["id" .= evolutionIdName identity, "path" .= path, "beforeRevision" .= revisionName revision, "state" .= ("Draft" :: String)])
  ["Created draft " ++ evolutionIdName identity, "Before " ++ revisionName revision, path]

summariesResult :: [EvolutionSummary] -> Response
summariesResult summaries = success (object ["evolutions" .= map summaryJson summaries])
  (if null summaries then ["No evolutions."] else map summaryText summaries)

inspectionResult :: (EvolutionSummary, Maybe EvolutionReport) -> Response
inspectionResult (summary, report) = success
  (object ["evolution" .= summaryJson summary, "report" .= fmap reportJson report])
  ([summaryText summary] ++ maybe ["No saved report."] reportText report)

candidateResult :: Candidate Root -> Response
candidateResult (Candidate (EvolutionContext _ identity (Before revision _) _) report (Root schema _ _ _)) = success
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
       ". If this evolution was already committed, inspect git status and restore the checkout from Git. " ++
       "Otherwise update Before and check the evolution again.")]
    NotReady Accepted -> [errorDiagnostic "acceptance.not-ready" "Evolution is already Accepted."]
    NotReady state -> [errorDiagnostic "acceptance.not-ready" ("Evolution is " ++ show state ++ "; mark it ready before accepting.")]
    CheckoutMismatch (LocalBranch selected) actual -> [errorDiagnostic "acceptance.checkout-mismatch"
      ("Expected checked-out branch " ++ selected ++ "; found " ++ maybe "detached HEAD" (\(LocalBranch name) -> name) actual)]
    WorkspaceChanged identity -> [errorDiagnostic "acceptance.workspace-changed"
      ("Inputs changed for " ++ evolutionIdName identity ++ "; check it again.")]
    OverlappingEdits paths -> [errorDiagnostic "acceptance.overlapping-edits"
      ("Resolve local edits before accepting: " ++ unwords (map relativeName paths))]
    InvalidMaterial diagnostics -> diagnostics)
  AcceptedCommit revision outcome -> checkoutResult "Accepted" revision revision outcome
checkoutResult :: String -> GitRevision -> GitRevision -> WorkingTreeOutcome -> Response
checkoutResult label accepted current outcome = Response
  (case outcome of WorkingTreeUpdated -> Succeeded; WorkingTreeUpdateIncomplete _ -> Incomplete)
  (object ["accepted" .= True, "acceptingCommit" .= revisionName accepted, "checkoutRevision" .= revisionName current,
    "checkoutUpdated" .= (outcome == WorkingTreeUpdated)])
  [label ++ " at " ++ revisionName accepted ++ case outcome of
    WorkingTreeUpdated -> "; checkout synchronized."
    WorkingTreeUpdateIncomplete _ -> "; checkout incomplete. Follow the Git restore instructions below."]
  (case outcome of WorkingTreeUpdated -> []; WorkingTreeUpdateIncomplete diagnostics -> diagnostics)

summaryJson :: EvolutionSummary -> Value
summaryJson (EvolutionSummary (EvolutionWorkspace _ identity) (EvolutionName name) state) = object
  ["id" .= evolutionIdName identity, "name" .= name, "state" .= show state]

summaryText :: EvolutionSummary -> String
summaryText (EvolutionSummary (EvolutionWorkspace _ identity) (EvolutionName name) state) =
  evolutionIdName identity ++ "  " ++ show state ++ "  " ++ name

reportJson :: EvolutionReport -> Value
reportJson (EvolutionReport plugins steps) = object
  ["steps" .= map step steps,
   "plugins" .= [object ["name" .= pluginNameText name, "before" .= fmap originJson old,
      "after" .= fmap originJson new, "files" .= map relativeName paths] | PluginChange name old new paths <- plugins]]
  where
    step (StepReport (Rationale explanation evidence) changes) = object
      ["explanation" .= explanation, "evidence" .= map evidenceJson evidence, "changes" .= map change changes]
    change (FactChange collection (FactId identity) before after) = object
      ["kind" .= ("Fact" :: String), "collection" .= collection, "id" .= identity, "before" .= fmap recorded before, "after" .= fmap recorded after]
    change (RecipeChange (FactId identity) before after) = object
      ["kind" .= ("Recipe" :: String), "id" .= identity, "before" .= fmap recipeJson before, "after" .= fmap recipeJson after]
    recipeJson (StoredRecipe method stateType _ (CheckedValue _ state)) = object
      ["method" .= methodJson method,"stateType" .= stateType,"state" .= state]
    methodJson (OpenAgent instructions) = object ["kind" .= ("OpenAgent" :: String),"instructions" .= instructions]
    methodJson (ClosedAgent (FlowEntryRef entry)) = object ["kind" .= ("ClosedAgent" :: String),"flow" .= entry]
    recorded (RecordedFact contract value) = object ["schema" .= describeRootContract contract, "value" .= value]
    evidenceJson (EvidenceRef producer connector source references) = object
      ["producer" .= producer, "instance" .= connector, "source" .= source, "externalReferences" .= references]

reportText :: EvolutionReport -> [String]
reportText (EvolutionReport plugins steps) = concatMap pluginLines plugins ++ concatMap step steps
  where
    pluginLines (PluginChange name old new paths) =
      ["Plugin " ++ pluginNameText name ++ ": " ++ revision old ++ " → " ++ revision new]
      ++ ["  before source: " ++ maybe "(absent)" originText old, "  after source:  " ++ maybe "(absent)" originText new]
      ++ ["  changed: " ++ relativeName path | path <- paths]
    revision = maybe "(absent)" (\(PluginOrigin _ _ selected) -> take 8 (revisionName selected))
    step (StepReport (Rationale explanation evidence) changes) = [Text.unpack explanation]
      ++ ["  Declared citations:" | not (null evidence)]
      ++ ["    " ++ Text.unpack source ++ " " ++ unwords (map Text.unpack references) | EvidenceRef _ _ source references <- evidence]
      ++ concatMap change changes
    change (FactChange collection (FactId identity) before after) =
      ["  " ++ collection ++ "/" ++ Text.unpack identity]
      ++ ["    before: " ++ maybe "(absent)" value before, "    after:  " ++ maybe "(absent)" value after]
    change (RecipeChange (FactId identity) before after) =
      ["  Recipe: " ++ Text.unpack identity,
       "    before: " ++ maybe "(absent)" recipeText before,
       "    after:  " ++ maybe "(absent)" recipeText after]
    recipeText (StoredRecipe method stateType _ (CheckedValue _ state)) =
      methodText method ++ "; state (" ++ stateType ++ "): " ++ Text.unpack (Text.decodeUtf8 (Bytes.toStrict (encode state)))
    methodText (OpenAgent instructions) = "Open agent: " ++ Text.unpack instructions
    methodText (ClosedAgent (FlowEntryRef entry)) = "Closed agent: " ++ Text.unpack entry
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
  show severity ++ " [" ++ Text.unpack code ++ "] " ++ Text.unpack message ++ maybe "" (\value -> " (" ++ locationText value ++ ")") location
  where
    locationText (FactLocation collection identity field) = Text.unpack collection ++ "/" ++ Text.unpack identity ++ maybe "" (('.' :) . Text.unpack) field
    locationText (SourceLocation path line column) = Text.unpack path ++ ":" ++ show line ++ ":" ++ show column
    locationText (ExampleLocation name) = "example " ++ Text.unpack name

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
