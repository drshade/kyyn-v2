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
import Kyyn.Domain.Path (DirectoryScope)
import Kyyn.Porcelain.Capability.Inspection
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Store
import Kyyn.Porcelain.Interpreter.Inspection (runInspection)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Surfaces.Result (Response, refusal, operationalFailure)
import Kyyn.Web.Inspection

inspectPage :: Host -> DirectoryScope -> [Text] -> [(ByteString,Maybe ByteString)]
  -> IO (Either Response (Html ()))
inspectPage host scope path parameters = case selection of
  Left diagnostics -> pure (Left (refusal diagnostics))
  Right (selected,route) -> do
    kbResult <- selectKnowledgeBase host scope
    case kbResult of
      Left response -> pure (Left response)
      Right (SelectedKb kb revision _) -> do
        result <- withRuntimeResult host $ \settings -> runRuntime host settings . runPluginPreparation . runToolPreparation
          . runRootOpening . runWorkspaceStore . runEvolutionStore . runInspection $ runExceptT $ do
            snapshot <- ExceptT (Right <$> inspectSnapshot kb revision selected)
            summaries <- case route of
              IndexPage -> ExceptT (Store.listEvolutions kb AllEvolutions)
              _ -> pure []
            details <- case route of
              EvolutionPage identity -> Just <$> ExceptT (inspectEvolutionSource (EvolutionWorkspace kb identity))
              _ -> pure Nothing
            ExceptT (pure (renderInspection selected snapshot route summaries details))
        pure $ case result of
          Left response -> Left response
          Right (Left failure) -> Left (operationalFailure failure)
          Right (Right (Left diagnostics)) -> Left (refusal diagnostics)
          Right (Right (Right page)) -> Right page
  where
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
        _ -> Left [errorDiagnostic "inspection.unknown" "Unknown inspection page"]
      Right (selected,route)
    checkedId value = either (bad . Text.pack) Right (evolutionId (Text.unpack value))
    bad message = Left [errorDiagnostic "inspection.selector" (Text.unpack message)]
