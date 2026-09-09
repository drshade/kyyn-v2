{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=))
import Data.List (isInfixOf)
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
import Kyyn.Domain.KnowledgeBase
import Kyyn.Domain.Path
import Kyyn.Domain.Publication
import Kyyn.Domain.Root
import Kyyn.Domain.Workspace
import Kyyn.Types.SchemaMetadata
import Kyyn.Porcelain.Capability.EvolutionStore
import Kyyn.Porcelain.Capability.RootOpening
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Surfaces.Actions
import Kyyn.Surfaces.Cli (RootCommand(..))
import Kyyn.Surfaces.Result

main :: IO ()
main = do
  let right :: Show e => Either e a -> a
      right = either (error . show) id
      empty = right (fileTree [])
      schema = right (checkContract
        (Algebraic "Example.Root" [] [Constructor "Example.Root" [(Just "title",StringType)]])
        (SchemaMetadata [] [] []) >>= checkRootLayout)
      root = Root schema empty empty
      value = CheckedValue (contractId (rootSchema schema)) (object ["title" .= ("Unicode λ" :: String)])
      scope = right (directoryScope "/test/repository")
      kb = KnowledgeBase (Repository scope) (Subtree (right (relativePath "nested/kb")))
      revision = right (gitRevision (replicate 40 'a'))
      identity = right (evolutionId "abc")
      workspace = EvolutionWorkspace kb identity
      captured = EvolutionContext kb identity (Before revision schema)
        (WorkspaceSnapshot (WorkspaceManifest revision "Example" "" Draft []) empty empty empty empty)
      candidate = Candidate captured (EvolutionReport []) root
      assert label condition = unless condition (fail label)
      runRoot :: RootCommand -> (Response, [String])
      runRoot request = runPureEff . runState ([] :: [String]) . storeRoot value . execution
        . opening kb revision root $ inspectRoot kb revision request
      runCandidate :: Maybe (Candidate Root) -> (Response, [String])
      runCandidate selected = runPureEff . runState ([] :: [String]) . storeRoot value . execution
        . candidates selected $ checkWorkspace workspace
      (shown, showCalls) = runRoot ShowRoot
      (checked, checkCalls) = runRoot CheckRoot
      (candidateChecked, candidateCalls) = runCandidate (Just candidate)
      (missing, missingCalls) = runCandidate Nothing
  assert "Root show bypassed checks or used wrong selection"
    (showCalls == ["open","code","queries","examples","validate","value"] && exitStatus shown == 0)
  assert "Root check decoded a browsing value" (checkCalls == ["open","code","queries","examples","validate"] && exitStatus checked == 0)
  assert "Candidate check opened or evaluated an evolution"
    (candidateCalls == ["candidate","code","queries","examples","validate"] && exitStatus candidateChecked == 0)
  assert "Missing candidate invoked validation" (missingCalls == ["candidate"] && exitStatus missing == 1)
  case shown of
    Response _ _ messages warnings -> do
      assert "Unicode human output was corrupted" (any (isInfixOf "Unicode λ") messages)
      assert "Warning disappeared" (warnings == [warning])
  assert "Validation rejection exit" (exitStatus (validationResult "root" (ValidationReport []) False) == 1)
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
  CheckRootCode _ -> record "code" >> pure (Right ())
  DiscoverQueries _ -> record "queries" >> pure (Right [])
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
