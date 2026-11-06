module Kyyn.Porcelain.Protocol.OutputBindings (prepareOutputs) where

import Control.Monad (unless)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Output (OutputDefinition(..), SinkReference(..))
import Kyyn.Domain.Plugin (MethodName(..))
import Kyyn.Domain.Query (QueryDescriptor(..))
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.RootExecution.Types (PreparedQuery(..), PreparedOutput(..))

-- The same Root guest has already typechecked query result against sink input.
-- Host preparation resolves the authored names to its checked runtime handles.
prepareOutputs :: [PreparedQuery] -> [PreparedPlugin] -> [OutputDefinition]
  -> Either [Diagnostic] [PreparedOutput]
prepareOutputs queries plugins = traverse $ \definition@(OutputDefinition name _ query (SinkReference plugin instanceName method)) -> do
  let bad message = Left [errorDiagnostic "output.binding" (name ++ ": " ++ message)]
  unless (method == MethodName "publish") (bad "Sink method must be publish")
  descriptor <- case [d | PreparedQuery d@(QueryDescriptor n _ _ _) _ _ <- queries, n == query] of
    [selected] -> pure selected
    _ -> bad ("Unknown registered query " ++ query)
  (_,configured@(ConfiguredConnector _ _ connector _)) <- selectedInstance plugin instanceName plugins
  case connector of
    PreparedSinkConnector{} -> pure (PreparedOutput definition descriptor configured)
    PreparedConnector{} -> bad "Selected connector is a source, not a sink"
