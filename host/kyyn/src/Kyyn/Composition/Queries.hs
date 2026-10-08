module Kyyn.Composition.Queries (dispatchQueries) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Kyyn.Configuration (Host, SelectedKb(..))
import Kyyn.Composition.Runtime
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.DataType (Shape(..))
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Query (QueryDescriptor(..), QueryResult(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (renderType, decodeValue, encodeValue)
import qualified Kyyn.Porcelain.Capability.Root as Root
import Kyyn.Porcelain.Capability.RootExecution (preparedQueries, queryRoot)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Queries
import Kyyn.Surfaces.RootBrowsing (browsingContext)
import Kyyn.Surfaces.Result (Response, refusal)

dispatchQueries :: Host -> Cli.QueryCommand -> SelectedKb -> IO Response
dispatchQueries host command (SelectedKb kb revision _) = withRuntime host $ \toolchain sdk -> finish $
  fmap (fmap (either refusal (browsingContext revision Nothing))) $
  runRuntime host toolchain . runPluginPreparation sdk . runToolPreparation sdk . runRootOpening sdk . runRootExecution sdk $ runExceptT $ do
    prepared <- ExceptT (Root.prepareRootAt kb revision)
    let queries = preparedQueries prepared
        select name = case [q | q@(QueryDescriptor n _ _ _) <- queries, n == name] of
          [query] -> pure query
          _ -> throwE [errorDiagnostic "query.unknown" ("No registered query named " ++ name)]
    case command of
      Cli.ListQueries -> pure (queryListResult queries)
      Cli.ShowQuery name -> do
        descriptor@(QueryDescriptor _ _ input output) <- select name
        queryDescriptionResult descriptor <$> (ExceptT (Right <$> renderType (contractShape input)))
          <*> (ExceptT (Right <$> renderType (contractShape output)))
      Cli.ExecuteQuery name supplied -> do
            descriptor@(QueryDescriptor _ _ input output) <- select name
            arguments <- case supplied of
              Just text -> ExceptT (decodeValue (contractShape input) (Text.pack text))
              Nothing | contractShape input == Record [] -> ExceptT (decodeValue (Record []) (Text.pack "{=}"))
              Nothing -> throwE [errorDiagnostic "query.arguments" "This query requires --input; inspect its contract with root query show."]
            result@(QueryResult (CheckedValue _ value) _) <- ExceptT (queryRoot prepared descriptor (CheckedValue (contractId input) arguments))
            rendered <- ExceptT (encodeValue (contractShape output) value)
            pure (queryValueResult result rendered)
