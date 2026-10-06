module Kyyn.Composition.RootBrowsing (dispatchSchema, dispatchCollection, dispatchFacts) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Kyyn.Configuration (Host, SelectedKb(..))
import Kyyn.Composition.Runtime
import Kyyn.Domain.Contract (CollectionContract(..))
import Kyyn.Domain.DataType (shapeOf)
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Root (Root(..), SourceRoot(..))
import Kyyn.Plumbing.Capability.DhallHandling (renderType, encodeValue)
import qualified Kyyn.Porcelain.Capability.Root as Root
import Kyyn.Porcelain.Capability.RootStore (readCollection)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import Kyyn.Porcelain.Validated (validatedValue)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.RootBrowsing
import Kyyn.Surfaces.Result (Response(..), refusal)
import Kyyn.Types.Fact (Fact(..), FactId(..))

dispatchSchema :: Host -> Cli.SchemaCommand -> SelectedKb -> IO Response
dispatchSchema host command (SelectedKb kb revision _) = withRuntime host $ \toolchain sdk -> finish $
  fmap (fmap (either refusal (browsingContext revision workspace))) $
    runRuntime host toolchain . runRootOpening sdk . runWorkspaceStore . runEvolutionStore $ runExceptT $ do
      SourceRoot contract _ _ _ <- ExceptT (Root.sourceRootAt kb revision workspace)
      case command of
        Cli.ListSchemas _ -> pure (schemaListResult contract)
        Cli.ShowSchema name _ -> do
          selected <- ExceptT (pure (Root.selectSchemaType contract name))
          shape <- ExceptT (pure (either (Left . pure . errorDiagnostic "schema.shape") Right (shapeOf selected)))
          rendered <- ExceptT (Right <$> renderType shape)
          pure (schemaResult contract selected rendered)
  where workspace = case command of Cli.ListSchemas target -> target; Cli.ShowSchema _ target -> target

dispatchCollection :: Host -> Cli.CollectionCommand -> SelectedKb -> IO Response
dispatchCollection host command (SelectedKb kb revision _) = withRuntime host $ \toolchain sdk -> finish $
  fmap (fmap (either refusal (browsingContext revision workspace))) $
    runRuntime host toolchain . runRootOpening sdk . runWorkspaceStore . runEvolutionStore $ runExceptT $ do
      SourceRoot contract _ _ _ <- ExceptT (Root.sourceRootAt kb revision workspace)
      case command of
        Cli.ListCollections _ -> pure (collectionListResult contract)
        Cli.ShowCollection name _ -> do
          selected@(CollectionContract _ _ _ shape) <- ExceptT (pure (Root.selectCollection contract name))
          rendered <- ExceptT (Right <$> renderType shape)
          pure (collectionResult contract selected rendered)
  where workspace = case command of Cli.ListCollections target -> target; Cli.ShowCollection _ target -> target

dispatchFacts :: Host -> Cli.FactCommand -> SelectedKb -> IO Response
dispatchFacts host command (SelectedKb kb revision _) = withRuntime host $ \toolchain sdk -> finish $
  runRuntime host toolchain . runRootOpening sdk . runPluginPreparation sdk . runToolPreparation sdk . runRootExecution sdk $ do
    checked <- Root.checkRootAt kb revision
    case checked of
      Rejected (ValidationReport diagnostics) -> pure (refusal diagnostics)
      Passed root (ValidationReport warnings) -> do
        result <- runExceptT $ do
          let Root contract _ _ _ _ = validatedValue root
          selected@(CollectionContract _ _ _ shape) <- ExceptT (pure (Root.selectCollection contract collection))
          facts <- ExceptT (readCollection root collection)
          case command of
            Cli.ListFacts _ -> pure (factListResult contract selected facts)
            Cli.ShowFact _ identity -> case [fact | fact@(Fact (FactId actual) _) <- facts, actual == Text.pack identity] of
              [fact@(Fact _ value)] -> do
                rendered <- ExceptT (encodeValue shape value)
                pure (factResult collection fact rendered)
              _ -> throwE [errorDiagnostic "fact.unknown" ("Unknown fact: " ++ collection ++ "/" ++ identity)]
        let Response outcome value messages diagnostics = either refusal (browsingContext revision Nothing) result
        pure (Response outcome value messages (warnings ++ diagnostics))
  where collection = case command of Cli.ListFacts name -> name; Cli.ShowFact name _ -> name
