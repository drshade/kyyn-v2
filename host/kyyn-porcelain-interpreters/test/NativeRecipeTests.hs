-- Real Nix recipe guest and native preparation/execution/rendering. The supplied
-- executable fixes compilation; selecting any other guest mode is rejected.
-- An empty captured evidence index supplies the nested connector callback.
-- Interactive attempts use fresh guest processes and the native journal; after
-- suspension any repeated connector read fails the test.
{-# LANGUAGE GHC2021, GADTs, OverloadedStrings, OverloadedRecordDot, DataKinds, TypeFamilies #-}
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=), toJSON)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.Foldable as Foldable
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import Effectful (Eff, DispatchOf, Dispatch(..), runEff)
import Effectful.Dispatch.Dynamic (interpret)
import System.Directory (canonicalizePath)
import System.Environment (getArgs)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.RecipeRun (PreparedRecipeRun(..))
import Kyyn.Domain.Git (Repository(..), TreePath(..), gitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.CompiledEntry (entryProgram, compiledEntries, invocationName)
import Kyyn.Porcelain.Capability.FlowJournal (FlowJournalIdentity(..))
import Kyyn.Porcelain.Interpreter.FlowJournal (runFlowJournal)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Protocol.Tool (encodeFlowValue)
import Kyyn.Porcelain.Protocol.ToolBroker (executeInteractiveRecipeProgram)
import Kyyn.Porcelain.Capability.RecipeRunStore (withRecipeRun)
import Kyyn.Porcelain.Interpreter.RecipeRunStore (runRecipeRunStore)
import Kyyn.Plumbing.Interpreter.AppendJournal (runAppendJournalIO)
import Kyyn.Domain.Contract (contractId, checkRootLayout)
import Kyyn.Domain.Guest (InspectedSchema(..), checkedEntries)
import Kyyn.Domain.Evidence (EvidenceSnapshotRef(..), ConnectorInstanceRef(..), EvidenceProducer(..), FetchId(..), FetchSummary(..))
import Kyyn.Domain.EvidenceIndex (EvidenceIndex(EvidenceIndex))
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin (packageIdentity, ConnectorTypeName(..))
import Kyyn.Domain.Root (SourceRoot(..), CheckedValue(..))
import qualified Kyyn.Domain.Recipe as R
import Kyyn.Domain.FactProposal (FactProposal(..), FactProposalStep(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Porcelain.Protocol.RecipeContracts (inspectRecipeContracts)
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage)
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection (describeGuest)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore(..))
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.RootStore (readRootDefinition, materializeRoot)
import Kyyn.Porcelain.Capability.RecipeExecution (PreparedRecipe(..), prepareRecipeFlow, executeRecipeFlow)
import Kyyn.Porcelain.Capability.RecipeInspection (describeRecipe)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import Kyyn.Porcelain.Interpreter.RecipeExecution (runRecipeExecution)
import Kyyn.Porcelain.Interpreter.RecipeInspection (runRecipeInspection)

main :: IO ()
main = do
  arguments <- getArgs
  executable <- case arguments of [selected] -> canonicalizePath selected; _ -> fail "Expected Nix recipe guest"
  let path = either error id . relativePath
  package <- mapM (\name -> (,) (path name) <$> Bytes.readFile ("tools/fixtures/captured-plugin/" ++ name))
    ["kyyn-plugin.dhall","src/Fixture/Plugin.hs"] >>= right . fileTree
  configuration <- Bytes.readFile "tools/fixtures/tool-guest/plugins/config/local-file.dhall"
  manifest <- Bytes.readFile "tools/fixtures/tool-guest/kb.dhall"
  code <- right (fileTree
    ([(path "flake.nix","{}"),(path "flake.lock","{}"),(path "kb.dhall",manifest),(path "plugins/config/local-file.dhall",configuration)] ++
     [(path ("plugins/packages/local-file/source/" ++ relativeName name),bytes) | (name,bytes) <- files package]))
  let program = CompiledProgram (BuildIdentity "fixture" "x86_64-linux" "fixture.drv" (takeDirectory (takeDirectory executable))) executable ".build/recipe-guest"
  withSystemTempDirectory "kyyn-native-recipe" $ \directory -> do
    scope <- right (directoryScope directory)
    prepared <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . fixedCompilation program . runPluginPreparation . runRootStore $ do
        description <- describeGuest program
        plugins <- case description of Left errors -> pure (Left errors); Right guest -> preparePluginsFromGuest code program guest
        definition <- readRootDefinition code
        pure (description,plugins,definition)
    (described,configured,defined) <- right prepared
    description <- right described
    plugins <- right configured
    definition <- right defined
    (schema,state) <- case [(root.contract,state.contract) | G.RecipeEntry _ "Flows.review" (G.RecipeContracts root _ state) <- checkedEntries description] of
      [selected] -> pure selected
      _ -> fail "Missing recipe"
    rootContract <- right (checkRootLayout schema)
    (plugin,payload) <- case [(name,payload) | PreparedPlugin (PreparedPackage name _ connectors) _ <- plugins,
        PreparedConnector {connectorType = ConnectorTypeName "Files",payloadContract = payload} <- connectors] of
      [selected] -> pure selected
      _ -> fail "Missing connector"
    let fetch = FetchId "fixture"
        snapshot = EvidenceSnapshotRef (ConnectorInstanceRef plugin "reader") (EvidenceProducer (packageIdentity package) (contractId payload)) fetch
        index = EvidenceIndex snapshot (FetchSummary fetch "now" 0 0 0 Nothing) payload mempty Nothing
        stateValue = CheckedValue (contractId state) (object ["runs" .= String "4"])
    result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . fixedCompilation program
      . unexpected @Judgement . unexpected @ModelTurn . unexpected @BlobStorage
      . capturedEvidence index . runPluginRead . runPluginPreparation . runRootStore
      . runAppendJournalIO . runRecipeRunStore (const (pure ())) . runRecipeInspection . runRecipeExecution $ do
        contracts <- inspectRecipeContracts (SourceRoot rootContract code definition [])
          [Fact (FactId "review") (R.ClosedRecipe (FlowEntryRef "Flows.review"))]
        rendered <- describeRecipe (SourceRoot rootContract code definition []) (FlowEntryRef "Flows.review") G.Tree
        stored <- materializeRoot rootContract code (R.KnowledgeBase (CheckedValue (contractId schema) (object ["items" .= ([] :: [Value])])) [])
        proposal <- case stored of
          Left errors -> pure (Left errors)
          Right root -> do
            preparation <- prepareRecipeFlow root (FlowEntryRef "Flows.review") stateValue Nothing
            case preparation of
              Left errors -> pure (Left errors)
              Right ready -> withRecipeRun (PreparedRecipeRun (KnowledgeBase (Repository scope) WholeTree)
                (R.RecipeId "review") (FlowEntryRef "Flows.review") (either error id (gitRevision (replicate 40 'a')))
                (entryProgram ready.entry).identity ready.graph ready.mermaid) (\writer -> executeRecipeFlow writer ready)
        pure (rendered,proposal,contracts)
    (rendered,proposal,contracts) <- right result
    states <- right contracts
    unless (case states of [(_,"Flows.State",actual)] -> actual == state; _ -> False)
      (fail "Private flow state contract/name differs from its guest descriptor")
    tree <- right rendered
    unless (not (Text.null tree)) (fail "Missing flow rendering")
    case proposal of
      Right (FactProposal [FactProposalStep _ [_]] (CheckedValue identity value))
        | identity == contractId state && value == object ["runs" .= String "5"] -> pure ()
      other -> fail ("Wrong native recipe result: " ++ show other)
    waitingEntry <- case filter ((== "$recipe.Flows.waiting") . invocationName) (compiledEntries program description) of
      [entry] -> pure entry
      _ -> fail "Missing waiting recipe"
    let kb = KnowledgeBase (Repository scope) WholeTree
        rootValue = object ["items" .= ([] :: [Value])]
        initial = object ["runs" .= String "4"]
        resume = G.ResumeRecipe "interactive-test" "pinned-fixture" rootValue (object []) initial
        identity = FlowJournalIdentity "interactive-test" "pinned-fixture" (toJSON resume)
        attempt first invocation = do
          outcome <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
            . runDhallHandling . runGuestExecution [("LC_ALL","C.UTF-8")]
            . unexpected @Judgement . unexpected @ModelTurn . unexpected @BlobStorage
            . (if first then capturedEvidence index else unexpected @EvidenceStore)
            . runPluginRead . runDocumentPersistenceIO . runFlowJournal kb identity $
              executeInteractiveRecipeProgram identity (const (pure ())) waitingEntry plugins Nothing (toJSON invocation)
          right outcome >>= right >>= successValue
    frontier <- attempt True resume >>= taggedValue "waiting"
    pending <- case frontier of
      Array values | [value] <- Foldable.toList values -> pure value
      _ -> fail "Expected one waiting point"
    let fulfil reply = G.FulfilRecipe "interactive-test" "pinned-fixture" pending (encodeFlowValue reply)
    rejected <- attempt False (fulfil (String "not an integer"))
    _ <- taggedValue "refused" rejected
    accepted <- attempt False (fulfil (Number 7))
    unless (accepted == object ["tag" .= String "accepted"]) (fail "Valid reply refused")
    duplicate <- attempt False (fulfil (Number 7))
    unless (duplicate == accepted) (fail "Identical fulfilment changed result")
    conflict <- attempt False (fulfil (Number 8))
    _ <- taggedValue "refused" conflict
    finished <- attempt False resume >>= taggedValue "finished"
    case finished of
      Object fields | Keys.lookup "state" fields == Just (object ["runs" .= String "7"]) -> pure ()
      _ -> fail ("Unexpected resumed proposal: " ++ show finished)
  putStrLn "Native recipe execution and rendering use the described guest, private state and nested captured connector."

fixedCompilation :: CompiledProgram -> Eff (GuestCompilation : es) a -> Eff es a
fixedCompilation program = interpret $ \_ (CompileGuest source) ->
  if selectedBuild source == RecipeEntries [ClosedFlow "Flows.review"] then pure (Right program)
  else error "Recipe path attempted a separate plugin or host-generated build"

capturedEvidence :: EvidenceIndex -> Eff (EvidenceStore : es) a -> Eff es a
capturedEvidence index = interpret $ \_ operation -> case operation of
  OpenCurrentEvidence _ -> pure (Right (Just index))
  _ -> error "Unexpected evidence mutation or read in empty snapshot"

unexpected :: DispatchOf effect ~ Dynamic => Eff (effect : es) a -> Eff es a
unexpected = interpret (\_ _ -> error "Unexpected external interaction in recipe fixture")
right :: Show e => Either e a -> IO a
right = either (fail . show) pure

successValue :: Value -> IO Value
successValue = taggedValue "Right"

taggedValue :: Text.Text -> Value -> IO Value
taggedValue tag (Object fields)
  | Keys.lookup "tag" fields == Just (String tag), Just value <- Keys.lookup "value" fields = pure value
taggedValue tag value = fail ("Expected " ++ Text.unpack tag ++ ": " ++ show value)
