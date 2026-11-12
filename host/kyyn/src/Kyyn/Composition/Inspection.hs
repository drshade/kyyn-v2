module Kyyn.Composition.Inspection (inspectPage) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Lucid (Html)
import Kyyn.Configuration (Host, SelectedKb(..), selectKnowledgeBase)
import Kyyn.Composition.Runtime
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.Inspection (EvolutionInspection(..), DeclarationRequest(..), LocalInspection(..))
import Kyyn.Domain.EvolutionReport (EvolutionReport(..))
import Kyyn.Domain.SnapshotReport (SnapshotStep(..))
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Domain.Evidence (EvidenceId(..))
import Kyyn.Domain.KnowledgeBase (knowledgeBaseScope)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Interpreter.BlobStorage (runBlobStorageIO)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Porcelain.Interpreter.EvidenceInspection (runEvidenceInspection)
import Kyyn.Domain.Workspace (WorkspaceManifest(..), EvolutionState(..))
import Kyyn.Domain.Path (DirectoryScope)
import Kyyn.Porcelain.Capability.Inspection
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Store
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import Kyyn.Porcelain.Interpreter.RecipeInspection (runRecipeInspection)
import Kyyn.Porcelain.Interpreter.Inspection (runInspection)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Surfaces.Result (Response(..), refusal, operationalFailure)
import Kyyn.Web.Inspection

inspectPage :: Host -> DirectoryScope -> [Text] -> [(ByteString,Maybe ByteString)]
  -> IO (Either (Response,Html ()) (Html ()))
inspectPage host scope path parameters = case selection of
  Left diagnostics -> pure (failed Nothing (refusal diagnostics))
  Right (selected,route) -> do
    kbResult <- selectKnowledgeBase host scope
    case kbResult of
      Left response -> pure (failed selected response)
      Right (SelectedKb kb revision _) -> case knowledgeBaseScope kb of
        Left message -> pure (failed selected (refusal [errorDiagnostic "kb.path" message]))
        Right kbScope -> do
          result <- withRuntimeResult host $ \settings -> runRuntime host settings . runDocumentPersistenceIO . runBlobStorageIO kbScope . runEvidenceStore kbScope
            . runEvidenceInspection . runPluginPreparation . runToolPreparation
            . runRootOpening . runWorkspaceStore . runEvolutionStore . runRootExecution . runRecipeInspection . runInspection $ runExceptT $ do
              details <- case route of
                EvolutionPage identity -> Just <$> ExceptT (inspectEvolutionSource (EvolutionWorkspace kb identity))
                _ -> pure Nothing
              -- A draft evolution owns its record context, even when reached from
              -- the accepted index or a link carrying another draft's selector.
              let shown = if localRoute route then Nothing else case (route,details) of
                    (EvolutionPage identity,Just (EvolutionInspection (WorkspaceManifest _ _ _ state _) _ _ _))
                      | state /= Accepted -> Just identity
                    _ -> selected
              snapshot <- ExceptT (Right <$> inspectSnapshot kb revision shown)
              summaries <- case route of
                IndexPage -> ExceptT (Store.listEvolutions kb AllEvolutions)
                _ -> pure []
              declaration <- case route of
                QueryPage name input -> Just <$> (ExceptT (pure snapshot) >>= \current -> ExceptT (inspectDeclaration current (QueryRequest name input)))
                ToolPage name -> Just <$> (ExceptT (pure snapshot) >>= \current -> ExceptT (inspectDeclaration current (ToolRequest name)))
                RecipePage name -> Just <$> (ExceptT (pure snapshot) >>= \current -> ExceptT (inspectDeclaration current (RecipeRequest name)))
                _ -> pure Nothing
              connectors <- ExceptT $ fmap Right $ case route of
                IndexPage -> do
                  accepted <- if shown == Nothing then pure snapshot else inspectSnapshot kb revision Nothing
                  either (pure . Left) inspectConnectors accepted
                _ | localRoute route -> either (pure . Left) inspectConnectors snapshot
                _ -> pure (Right [])
              item <- case route of
                EvidencePage plugin name key -> do
                  connector <- ExceptT (pure (connectorFor (LocalInspection connectors Nothing []) plugin name))
                  Just <$> ExceptT (inspectEvidenceItem connector (EvidenceId key))
                _ -> pure Nothing
              let evidence = case details of
                    Just (EvolutionInspection _ _ (Just (EvolutionReport _ steps)) _) ->
                      concat [refs | SnapshotStep _ (Rationale _ refs) _ <- steps]
                    _ -> []
              references <- ExceptT (Right <$> inspectEvidenceReferences kb revision evidence)
              ExceptT (pure (renderInspection shown snapshot route summaries details declaration (LocalInspection connectors item references)))
          pure $ case result of
            Left response -> failed selected response
            Right (Left failure) -> failed selected (operationalFailure failure)
            Right (Right (Left diagnostics)) -> failed selected (refusal diagnostics)
            Right (Right (Right page)) -> Right page
  where
    failed selected response@(Response _ _ _ diagnostics) =
      Left (response,renderInspectionError selected diagnostics)
    selection = do
      selected <- case [value | ("evolution",value) <- parameters] of
        [] -> Right Nothing
        [Just raw] -> case Text.decodeUtf8' raw of
          Left _ -> bad "Invalid evolution selector"
          Right value -> Just <$> checkedId value
        _ -> bad "Supply exactly one nonempty evolution selector"
      route <- case path of
        [] -> Right IndexPage
        ["evolutions",identity] -> EvolutionPage <$> checkedId identity
        ["collections",name] -> Right (CollectionPage (Text.unpack name))
        ["records",name,identity] -> Right (RecordPage (Text.unpack name) identity)
        ["types",name] -> Right (TypePage (Text.unpack name))
        ["connectors",plugin,name] -> Right (ConnectorPage plugin name)
        ["connectors",plugin,name,"types",role,typ] -> Right (CaptureTypePage plugin name role (Text.unpack typ))
        ["evidence",plugin,name,key] -> Right (EvidencePage plugin name key)
        ["queries",name] -> QueryPage (Text.unpack name) <$> inputParameter
        ["tools",name] -> Right (ToolPage (Text.unpack name))
        ["recipes",name] -> Right (RecipePage name)
        ["recipes",name,"types",typ] -> Right (RecipeTypePage name (Text.unpack typ))
        _ -> Left [errorDiagnostic "inspection.unknown" "Unknown inspection page"]
      Right (selected,route)
    inputParameter = case [value | ("input",value) <- parameters] of
      [] -> Right Nothing
      [Just raw] -> case Text.decodeUtf8' raw of
        Left _ -> bad "Input must be UTF-8"
        Right value -> Right (Just value)
      _ -> bad "Supply exactly one input value"
    checkedId value = either (bad . Text.pack) Right (evolutionId (Text.unpack value))
    bad message = Left [errorDiagnostic "inspection.selector" (Text.unpack message)]
