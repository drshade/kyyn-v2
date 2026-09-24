{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module Main (main) where

import Kyyn.Domain.Curation (emptyCurationRegister)
import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=))
import Data.List (isInfixOf, elemIndex)
import Effectful (Eff, (:>), runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.State.Static.Local (State, modify, runState)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport (EvolutionReport(..))
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Domain.Git
import qualified Kyyn.Domain.GuestApi as Api
import Kyyn.Domain.KnowledgeBase
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin (pluginName, connectorName)
import Kyyn.Surfaces.Connectors (clearResult)
import Kyyn.Domain.Publication
import Kyyn.Domain.Root
import Kyyn.Domain.Workspace
import Kyyn.Types.SchemaMetadata
import Kyyn.Porcelain.Capability.EvolutionStore
import Kyyn.Porcelain.Capability.RootOpening
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..))
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Capability.Root (inspectRootAt, checkRootAt)
import Kyyn.Porcelain.Capability.Evolution (checkSavedCandidate)
import Kyyn.Surfaces.Cli (RootCommand(..))
import Kyyn.Surfaces.Result
import qualified Kyyn.Surfaces.GuestApi as GuestApi

main :: IO ()
main = do
  let plugin = either error id (pluginName "local-file")
      instanceName = either error id (connectorName "sales")
  mapM_ (\(existed,expected) -> case clearResult plugin instanceName existed of
    Response _ payload messages _ -> unless
      (payload == object ["plugin" .= ("local-file" :: String),"connector" .= ("sales" :: String),"cleared" .= existed]
        && messages == [expected ++ "local-file/sales"])
      (fail "Clear output did not distinguish existing and absent evidence"))
    [(True,"Cleared evidence for "),(False,"No cached evidence for ")]
  let render name namespace origin signature = case GuestApi.symbolResult
        (Right ("Example", [Api.ApiSymbol name namespace origin signature Nothing Nothing])) of
        Response _ _ messages _ -> unlines messages
  unless ("\n(>>=) :: " `isInfixOf` render ">>=" Api.ValueNamespace "Example.>>=" "a -> b")
    (fail "Compiler operator signatures must be parenthesized")
  unless ("\ntype Opaque :: Type  -- [compiler signature]" `isInfixOf`
      render "Opaque" Api.TypeNamespace "Example.Opaque" "Type")
    (fail "Kind fallback must retain type namespace")
  unless ("Defined as Example.source" `isInfixOf`
      render "source" Api.ValueNamespace "Example.get$.Record.source" "Record -> String")
    (fail "Accessor origins must be readable")
  unless ("Defined as Example.get$.Record.different" `isInfixOf`
      render "source" Api.ValueNamespace "Example.get$.Record.different" "Record -> String")
    (fail "Unrecognized compiler origins must be preserved")
  let right :: Show e => Either e a -> a
      right = either (error . show) id
      empty = right (fileTree [])
      schema = right (checkContract
        (Algebraic "Example.Root" [] [Constructor "Example.Root" [(Just "title",StringType)]])
        (SchemaMetadata [] [] []) >>= checkRootLayout)
      root = Root schema empty empty emptyCurationRegister []
      value = CheckedValue (contractId (rootSchema schema)) (object ["title" .= ("Unicode λ" :: String)])
      scope = right (directoryScope "/test/repository")
      kb = KnowledgeBase (Repository scope) (Subtree (right (relativePath "nested/kb")))
      revision = right (gitRevision (replicate 40 'a'))
      identity = right (evolutionId "abc")
      workspace = EvolutionWorkspace kb identity
      captured = EvolutionContext kb identity (Before revision schema)
        (WorkspaceSnapshot (WorkspaceManifest revision "Example" "" Draft) empty empty empty empty)
      candidate = Candidate captured (EvolutionReport [] Nothing) root
      assert label condition = unless condition (fail label)
      runRoot :: RootCommand -> (Response, [String])
      runRoot request = runPureEff . runState ([] :: [String]) . storeRoot value . execution
        . opening kb revision root $ case request of
          ShowRoot -> inspectionCheckResult revision <$> inspectRootAt kb revision
          CheckRoot -> checkResult "Root" <$> checkRootAt kb revision
          RootTool _ -> error "Tool commands have their own dispatcher"
          RootRecipe _ -> error "Recipe commands have their own dispatcher"
      runCandidate :: Maybe (Candidate Root) -> (Response, [String])
      runCandidate selected = runPureEff . runState ([] :: [String]) . storeRoot value . execution
        . candidates selected $ checkResult "Candidate" <$> checkSavedCandidate workspace
      (shown, showCalls) = runRoot ShowRoot
      (checked, checkCalls) = runRoot CheckRoot
      (candidateChecked, candidateCalls) = runCandidate (Just candidate)
      (missing, missingCalls) = runCandidate Nothing
  assert "Root show bypassed checks or used wrong selection"
    (showCalls == ["open","prepare","examples","validate","value"] && exitStatus shown == 0)
  assert "Root check decoded a browsing value" (checkCalls == ["open","prepare","examples","validate"] && exitStatus checked == 0)
  assert "Candidate check opened or evaluated an evolution"
    (candidateCalls == ["candidate","prepare","examples","validate"] && exitStatus candidateChecked == 0)
  assert "Missing candidate invoked validation" (missingCalls == ["candidate"] && exitStatus missing == 1)
  let reexport = Api.ApiSymbol "append" Api.ValueNamespace "Kyyn.Edit.append" "a" (Just "append :: a") Nothing
      local = Api.ApiSymbol "edit" Api.ValueNamespace "Kyyn.Workspace.Evolution.edit" "b" (Just "edit :: b") (Just "Edit this root.")
      apiModule = Api.ApiModule "Kyyn.Workspace.Evolution" [reexport,local]
      catalogue = Api.WorkspaceCatalogue workspace revision [apiModule]
      rendered = GuestApi.moduleResult (Right apiModule)
      unavailable = refusal [errorDiagnostic "plugin.config" "Repair connector configuration"]
  case GuestApi.availableCatalogue True [apiModule] unavailable of
    Response outcome payload _ diagnostics -> do
      assert "Unavailable bindings erased the fixed catalogue" (outcome == Succeeded &&
        payload == object ["modules" .= (["Kyyn.Workspace.Evolution"] :: [String])])
      assert "Partial catalogue lacks warning" (case diagnostics of
        Diagnostic Warning "guest.bindings-unavailable" _ _ : Diagnostic Warning "plugin.config" _ _ : [] -> True
        _ -> False)
  assert "Unavailable requested module succeeded"
    (exitStatus (GuestApi.availableCatalogue False [apiModule] unavailable) == 1)
  let unknown = refusal [errorDiagnostic "guest.module-not-found" "Unknown module"]
  assert "Unknown module misreported as broken bindings" (GuestApi.availableCatalogue False [apiModule] unknown == unknown)
  assert "Successful discovery changed" (GuestApi.availableCatalogue True [apiModule] rendered == rendered)
  case rendered of
    Response _ _ messages _ ->
      assert "Workspace local declarations precede reexports"
        (elemIndex "edit :: b" messages < elemIndex "append :: a" messages)
  case GuestApi.workspaceResult catalogue (GuestApi.modulesResult (Right ["Kyyn.Workspace.Evolution"])) of
    Response _ payload messages _ -> do
      assert "Discovery context lost KB, workspace or declared revision"
        (payload == object ["modules" .= (["Kyyn.Workspace.Evolution"] :: [String]),
          "context" .= object ["kb" .= ("/test/repository/nested/kb" :: String),
            "evolution" .= evolutionIdName identity, "beforeRevision" .= revisionName revision]])
      assert "Human discovery context missing revision" (any (isInfixOf (revisionName revision)) messages)
  case shown of
    Response _ _ messages warnings -> do
      assert "Unicode human output was corrupted" (any (isInfixOf "Unicode λ") messages)
      assert "Warning disappeared" (warnings == [warning])
  assert "Validation rejection exit" (exitStatus (validationResult "root" (ValidationReport []) False) == 1)
  case workspaceResult workspace revision "/workspace" of
    Response _ payload messages _ -> do
      assert "Creation omitted its Before revision"
        (any (isInfixOf (revisionName revision)) messages)
      assert "Creation JSON omitted its Before revision"
        (payload == object ["id" .= evolutionIdName identity, "path" .= ("/workspace" :: String),
          "beforeRevision" .= revisionName revision, "state" .= ("Draft" :: String)])
  assert "Human fact location leaked constructors"
    (diagnosticText (Diagnostic Error "bad" "Invalid" (Just (FactLocation "todos" "001" (Just "title")))) ==
      "Error [bad] Invalid (todos/001.title)")
  assert "Human source location" (diagnosticText (Diagnostic Error "bad" "Invalid" (Just (SourceLocation "Schema.hs" 2 3))) ==
    "Error [bad] Invalid (Schema.hs:2:3)")
  assert "Human example location" (diagnosticText (Diagnostic Error "bad" "Invalid" (Just (ExampleLocation "receipt"))) ==
    "Error [bad] Invalid (example receipt)")
  assert "Accepted-complete exit" (exitStatus (acceptanceResult (AcceptedCommit revision WorkingTreeUpdated)) == 0)
  let incomplete = acceptanceResult (AcceptedCommit revision (WorkingTreeUpdateIncomplete [errorDiagnostic "sync" "locked"]))
  assert "Accepted-but-incomplete was hidden" (exitStatus incomplete == 4)
  assert "Already accepted implies no checked checkout"
    (exitStatus (acceptanceResult (AlreadyAccepted revision (errorDiagnostic "already" "recover"))) == 4)
  assert "Interruption exit" (exitStatus (interruption (Just identity)) == 130)
  assert "Recovery without acceptance exit" (exitStatus (recoveryResult Nothing) == 1)
  let failure = refusal [errorDiagnostic "bad" "Invalid"]
  assert "Stable diagnostic envelope" (responseJson failure == object
    ["outcome" .= ("Refused" :: String), "result" .= Null, "diagnostics" .=
      [object ["severity" .= ("Error" :: String),"code" .= ("bad" :: String),"message" .= ("Invalid" :: String),"location" .= Null]]])
  putStrLn "CLI adapters preserve selection, checks, diagnostics, Unicode and outcome exits."

warning :: Diagnostic
warning = Diagnostic Warning "review" "Review this root" Nothing

record :: State [String] :> es => String -> Eff es ()
record name = modify (++ [name])

opening :: State [String] :> es => KnowledgeBase -> GitRevision -> Root -> Eff (RootOpening : es) a -> Eff es a
opening kb@(KnowledgeBase repository _) revision root = interpret $ \_ -> \case
  LoadRootAt selected at (Subtree path)
    | selected == repository && at == revision && Right path == rootLocation kb -> record "open" >> pure (Right root)
  _ -> error "Wrong root operation or selection"

execution :: State [String] :> es => Eff (RootExecution : es) a -> Eff es a
execution = interpret $ \_ -> \case
  PrepareRoot root -> record "prepare" >> pure (Right (PreparedRoot root "validator" (error "Unexpected bytecode use") [] []))
  ValidateRoot _ -> record "validate" >> pure (Right (ValidationReport [warning]))
  _ -> error "Unexpected query execution"

storeRoot :: State [String] :> es => CheckedValue -> Eff (RootStore : es) a -> Eff es a
storeRoot value = interpret $ \_ -> \case
  ReadExamples _ _ -> record "examples" >> pure (Right [])
  LoadRootValueForChecking _ -> record "value" >> pure (Right value)
  _ -> error "Unexpected root-store operation"

candidates :: State [String] :> es => Maybe (Candidate Root) -> Eff (EvolutionStore : es) a -> Eff es a
candidates selected = interpret $ \_ -> \case
  LoadCandidate _ -> record "candidate" >> pure (Right selected)
  _ -> error "Unexpected evolution-store operation"
