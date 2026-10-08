{-# LANGUAGE DataKinds #-}
module Kyyn.Composition.Tools (dispatchTools) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import qualified Data.Text as Text
import Effectful (Eff)
import Kyyn.Configuration (Host, SelectedKb(..))
import Kyyn.Composition.Runtime
import Kyyn.Domain.Contract (contractShape)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.KnowledgeBase (knowledgeBaseScope)
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.MicroHs.Toolchain (GuestToolchain)
import Kyyn.Plumbing.Capability.DhallHandling (renderType, decodeValue, encodeValue)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Interpreter.SecretStore (runSecretStoreIO)
import Kyyn.Plumbing.Interpreter.Judgement (runJudgementIO)
import Kyyn.Plumbing.Interpreter.ModelTurn (runModelTurnIO)
import Kyyn.Porcelain.Capability.Tool
import Kyyn.Porcelain.Capability.Root (listRootTools, selectRootTool)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore)
import Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.ToolExecution (runToolExecution)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Plumbing.Interpreter.BlobStorage (runBlobStorageIO)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Connectors (methodOutputResult)
import Kyyn.Surfaces.Tools (toolListResult, toolResult)
import Kyyn.Surfaces.Result (Response, refusal)

type Discovery = EvolutionStore ': WorkspaceStore ': RootOpening ': ToolPreparation ': PluginPreparation ': Runtime

runDiscovery :: Host -> GuestToolchain -> FileTree -> Eff Discovery a -> IO (Either OperationalFailure a)
runDiscovery host toolchain sdk = runRuntime host toolchain . runPluginPreparation sdk . runToolPreparation sdk
  . runRootOpening sdk . runWorkspaceStore . runEvolutionStore

dispatchTools :: Host -> Cli.ToolCommand -> SelectedKb -> IO Response
dispatchTools host command (SelectedKb kb revision _) = withRuntime host $ \toolchain sdk -> case command of
  Cli.ListTools workspace -> finish $ fmap (fmap (either refusal (toolListResult . map descriptor))) $
    runDiscovery host toolchain sdk (listRootTools kb revision workspace)
  Cli.ShowTool name workspace -> finish $ fmap (fmap (either refusal id)) $
    runDiscovery host toolchain sdk $ runExceptT $ do
      PreparedTool (ToolDescriptor _ description input output) _ _ model <- ExceptT (selectRootTool kb revision workspace name)
      inputType <- ExceptT (Right <$> renderType (contractShape input))
      resultType <- ExceptT (Right <$> renderType (contractShape output))
      pure (toolResult name description inputType resultType model)
  Cli.ExecuteTool name arguments -> case knowledgeBaseScope kb of
    Left message -> pure (refusal [errorDiagnostic "kb.path" message])
    Right scope -> finish $ fmap (fmap (either refusal id)) $
      runRuntime host toolchain . runSecretStoreIO scope . runJudgementIO . runModelTurnIO
        . runDocumentPersistenceIO . (runBlobStorageIO scope . runEvidenceStore scope) . runPluginRead
        . runPluginPreparation sdk . runToolPreparation sdk . runRootOpening sdk . runWorkspaceStore . runEvolutionStore . runToolExecution $ runExceptT $ do
          selected@(PreparedTool (ToolDescriptor _ _ input output) _ _ _) <- ExceptT (selectRootTool kb revision Nothing name)
          value <- ExceptT (decodeValue (contractShape input) (Text.pack arguments))
          (CheckedValue _ result,blobs) <- ExceptT (executeTool selected value)
          rendered <- ExceptT (encodeValue (contractShape output) result)
          pure (methodOutputResult result rendered blobs)
  where descriptor (PreparedTool value _ _ _) = value
