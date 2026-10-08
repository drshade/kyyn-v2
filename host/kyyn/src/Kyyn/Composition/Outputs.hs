{-# LANGUAGE DataKinds #-}
module Kyyn.Composition.Outputs (dispatchOutputs) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value, object, (.=))
import Data.Coerce (coerce)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Configuration (Host, SelectedKb(..))
import Kyyn.Composition.Runtime
import Kyyn.Domain.Contract (contractShape, contractId, CheckedContract)
import Kyyn.Domain.DataType (Shape(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.KnowledgeBase (knowledgeBaseScope)
import Kyyn.Domain.Output (OutputDefinition(..), SinkReference(..), PublicationOutcome(..))
import Kyyn.Domain.Plugin (pluginNameText, ConnectorName(..), MethodName(..))
import Kyyn.Domain.Query (QueryDescriptor(..), QueryResult(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, renderType, decodeValue, encodeValue)
import Kyyn.Porcelain.Capability.Delivery (invokeSink)
import qualified Kyyn.Porcelain.Capability.Root as Root
import Kyyn.Porcelain.Capability.RootExecution (RootExecution, PreparedRoot, PreparedOutput(..), preparedOutputs, queryRoot)
import Kyyn.Porcelain.Capability.PluginPreparation (ConfiguredConnector(..), PreparedConnector(..))
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import Kyyn.Porcelain.Interpreter.Delivery (runDelivery)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.RootBrowsing (browsingContext)
import Kyyn.Surfaces.Result (Response(..), Outcome(..), success, refusal)

dispatchOutputs :: Host -> Cli.OutputCommand -> SelectedKb -> IO Response
dispatchOutputs host command (SelectedKb kb revision _) = withRuntime host $ \toolchain sdk ->
  let run action = finish $ fmap (fmap (either refusal (browsingContext revision Nothing))) $
        runRuntime host toolchain . runPluginPreparation sdk . runToolPreparation sdk . runRootOpening sdk . runRootExecution sdk $ runExceptT action
  in case command of
    Cli.PublishOutput name supplied suppliedOptions -> case knowledgeBaseScope kb of
      Left message -> pure (refusal [errorDiagnostic "kb.path" message])
      Right scope -> run $ do
        prepared <- ExceptT (Root.prepareRootAt kb revision)
        selected@(PreparedOutput _ _ configured) <- select prepared name
        (_,optionsType,resultType,defaults,_) <- sinkDetails selected
        options <- maybe (pure defaults) (arguments optionsType . Just) suppliedOptions
        content <- render prepared selected supplied
        outcome <- ExceptT (Right <$> runDelivery scope (invokeSink configured options content))
        case outcome of
          Acknowledged (CheckedValue _ value) -> do
            rendered <- ExceptT (encodeValue (contractShape resultType) value)
            pure (success (object ["publication" .= ("Acknowledged" :: String),"result" .= value]) [Text.unpack rendered])
          RejectedByDestination diagnostic -> pure (Response Refused (object ["publication" .= ("RejectedByDestination" :: String)]) [] [diagnostic])
          FailedBeforeDispatch diagnostic -> pure (Response Failed (object ["publication" .= ("FailedBeforeDispatch" :: String)]) [] [diagnostic])
          Uncertain diagnostic -> pure (Response Incomplete (object ["publication" .= ("Uncertain" :: String)]) [] [diagnostic])
    _ -> run $ do
      prepared <- ExceptT (Root.prepareRootAt kb revision)
      case command of
        Cli.ListOutputs -> pure (success
          (object ["outputs" .= [object ["name" .= n,"description" .= d,"query" .= q] |
            PreparedOutput (OutputDefinition n d q _) _ _ <- preparedOutputs prepared]])
          [n ++ "  " ++ d | PreparedOutput (OutputDefinition n d _ _) _ _ <- preparedOutputs prepared])
        Cli.ShowOutput name -> do
          selected@(PreparedOutput (OutputDefinition _ description query reference) (QueryDescriptor _ _ input output) _) <- select prepared name
          (configType,optionsType,resultType,CheckedValue _ defaults,config) <- sinkDetails selected
          inputText <- ExceptT (Right <$> renderType (contractShape input))
          outputText <- ExceptT (Right <$> renderType (contractShape output))
          optionsText <- ExceptT (Right <$> renderType (contractShape optionsType))
          resultText <- ExceptT (Right <$> renderType (contractShape resultType))
          defaultText <- ExceptT (encodeValue (contractShape optionsType) defaults)
          configText <- ExceptT (encodeValue (contractShape configType) config)
          pure (success (object ["name" .= name,"description" .= description,"query" .= query,
            "sink" .= sinkValue reference,"inputType" .= inputText,"contentType" .= outputText,
            "optionsType" .= optionsText,"resultType" .= resultText,"defaultOptions" .= defaults,"configuration" .= config])
            [name ++ " — " ++ description,"Query: " ++ query,"Sink: " ++ sinkLabel reference,
             "Input: " ++ Text.unpack inputText,"Content: " ++ Text.unpack outputText,
             "Options: " ++ Text.unpack optionsText,"Defaults: " ++ Text.unpack defaultText,
             "Result: " ++ Text.unpack resultText,"Configuration: " ++ Text.unpack configText])
        Cli.PreviewOutput name supplied -> do
          selected@(PreparedOutput (OutputDefinition _ _ _ reference) (QueryDescriptor _ _ _ output) _) <- select prepared name
          (configType,_,_,_,config) <- sinkDetails selected
          CheckedValue _ value <- render prepared selected supplied
          rendered <- ExceptT (encodeValue (contractShape output) value)
          configText <- ExceptT (encodeValue (contractShape configType) config)
          pure (success (object ["sink" .= sinkValue reference,"configuration" .= config,"content" .= value])
            ["Sink: " ++ sinkLabel reference,"Configuration: " ++ Text.unpack configText,Text.unpack rendered])

select :: PreparedRoot -> String -> ExceptT [Diagnostic] (Eff es) PreparedOutput
select prepared name = case [o | o@(PreparedOutput (OutputDefinition n _ _ _) _ _) <- preparedOutputs prepared, n == name] of
  [output] -> pure output
  _ -> throwE [errorDiagnostic "output.unknown" ("No registered output named " ++ name)]

sinkDetails :: PreparedOutput -> ExceptT [Diagnostic] (Eff es) (CheckedContract,CheckedContract,CheckedContract,CheckedValue,Value)
sinkDetails (PreparedOutput _ _ (ConfiguredConnector _ _ connector (CheckedValue _ config))) = case connector of
  PreparedSinkConnector {configContract = c,sinkOptionsContract = o,sinkResultContract = r,sinkDefaultOptions = defaults} -> pure (c,o,r,defaults,config)
  PreparedConnector{} -> throwE [errorDiagnostic "output.sink-required" "Output requires a sink connector"]

arguments :: DhallHandling :> es => CheckedContract -> Maybe String -> ExceptT [Diagnostic] (Eff es) CheckedValue
arguments contract supplied = do
  value <- case supplied of
    Just source -> ExceptT (decodeValue (contractShape contract) (Text.pack source))
    Nothing | contractShape contract == Record [] -> ExceptT (decodeValue (Record []) "{=}")
    Nothing -> throwE [errorDiagnostic "query.arguments" "This query requires --input; inspect root output show."]
  pure (CheckedValue (contractId contract) value)

render :: (DhallHandling :> es, RootExecution :> es) => PreparedRoot -> PreparedOutput -> Maybe String
  -> ExceptT [Diagnostic] (Eff es) CheckedValue
render prepared (PreparedOutput _ descriptor@(QueryDescriptor _ _ input _) _) supplied = do
  args <- arguments input supplied
  QueryResult result _ <- ExceptT (queryRoot prepared descriptor args)
  pure result

sinkLabel :: SinkReference -> String
sinkLabel (SinkReference plugin instanceName method) = pluginNameText plugin ++ "/" ++ coerce instanceName ++ "/" ++ coerce method

sinkValue :: SinkReference -> Value
sinkValue (SinkReference plugin instanceName method) = object
  ["plugin" .= pluginNameText plugin,"instanceName" .= (coerce instanceName :: String),"method" .= (coerce method :: String)]
