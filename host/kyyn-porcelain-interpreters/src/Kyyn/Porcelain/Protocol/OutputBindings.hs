module Kyyn.Porcelain.Protocol.OutputBindings (prepareOutputs) where

import Control.Monad (forM, unless)
import Control.Monad.Trans.Except (ExceptT(..), throwE)
import Data.List (stripPrefix, nub)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Contract (rootType)
import Kyyn.Domain.DataType (haskellType, typeModules)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Output (OutputDefinition(..), SinkReference(..))
import Kyyn.Domain.Path (relativeName, relativePath)
import Kyyn.Domain.Plugin (pluginNameText, MethodName(..))
import Kyyn.Domain.Query (QueryDescriptor(..))
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (guestSources)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.RootExecution.Types (PreparedQuery(..), PreparedOutput(..))

prepareOutputs :: GuestCompilation :> es => FileTree -> FileTree -> FileTree -> [PreparedQuery] -> [PreparedPlugin]
  -> [OutputDefinition] -> ExceptT [Diagnostic] (Eff es) [PreparedOutput]
prepareOutputs sdk authored code queries plugins = mapM $ \definition@(OutputDefinition name _ query (SinkReference plugin instanceName method)) -> do
  let bad message = throwE [errorDiagnostic "output.binding" (name ++ ": " ++ message)]
      checked = either bad pure
  unless (method == MethodName "publish") (bad "Sink method must be publish")
  descriptor@(QueryDescriptor _ _ _ output) <- case [d | PreparedQuery d@(QueryDescriptor n _ _ _) _ _ <- queries, n == query] of
    [d] -> pure d
    _ -> bad ("Unknown registered query " ++ query)
  (_,configured@(ConfiguredConnector _ _ connector _)) <- either throwE pure (selectedInstance plugin instanceName plugins)
  input <- case connector of
    PreparedSinkConnector {sinkInputContract = contract} -> pure contract
    PreparedConnector{} -> bad "Selected connector is a source, not a sink"
  let prefix = "plugins/packages/" ++ pluginNameText plugin ++ "/source/src/"
  pluginFiles <- forM [(name',bytes) | (path,bytes) <- files code, Just name' <- [stripPrefix prefix (relativeName path)]] $ \(path,bytes) ->
    (,) <$> checked (relativePath path) <*> pure bytes
  path <- checked (relativePath "KyynOutputBinding.hs")
  let resultType = rootType output
      inputType = rootType input
      adapter = unlines $ ["module KyynOutputBinding where"] ++
        ["import qualified " ++ m | m <- nub (typeModules resultType ++ typeModules inputType)] ++
        ["sinkInput :: " ++ haskellType inputType ++ " -> ()","sinkInput _ = ()",
         "rendererResult :: " ++ haskellType resultType ++ " -> ()","rendererResult = sinkInput",
         "main :: IO ()","main = pure ()"]
  sources <- checked (guestSources path (files sdk ++ files authored ++ pluginFiles ++ [(path,Text.encodeUtf8 (Text.pack adapter))]))
  _ <- ExceptT (compileGuest sources)
  pure (PreparedOutput definition descriptor configured)
