{-# LANGUAGE OverloadedRecordDot, DataKinds, TypeApplications #-}
-- | A frozen execution description. Source is pinned by Git and executable by
-- Nix; the bundle stores resolved descriptions/configuration, never source copies.
module Kyyn.Porcelain.Protocol.FlowBundle (bundleValue, parseBundle) where

import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=), (.:), withObject)
import Data.Aeson.Types (Parser)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.Coerce (coerce)
import Data.List (nub, sort)
import qualified Data.Text as Text
import GHC.Records (getField)
import Kyyn.Domain.CompiledProgram (CompiledProgram(..), BuildIdentity(..))
import Kyyn.Domain.CompiledEntry (CompiledConnector(..), compiledEntries, compiledConnectors, entryDescription)
import Kyyn.Domain.Contract (descriptionOf, metadataOf, contractId)
import Kyyn.Domain.FlowClosure (FlowDeclaration(..), flowClosure)
import Kyyn.Domain.Git (gitRevision, revisionName)
import Kyyn.Domain.Guest (checkGuest, checkedEntries, checkedModules, InspectedSchema(..))
import Kyyn.Domain.Model (ModelConfiguration(..))
import Kyyn.Domain.Path (relativeName, directoryScope)
import Kyyn.Domain.Plugin
import Kyyn.Domain.Recipe (RecipeDefinition(..))
import Kyyn.Domain.Secret (secretNameText)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Types.KnowledgeBase (RecipeId(..), FlowEntryRef(..), Lifetime(..))
import Kyyn.Plumbing.Protocol.ModelConfiguration (decodeConfiguration)
import Kyyn.Porcelain.Capability.FlowPreparation
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Protocol.PluginDescription (connectorDescription)

bundleValue :: FlowBundle -> Value
bundleValue bundle = object
  [ "revision" .= revisionName bundle.revision
  , "program" .= programValue bundle.program
  , "guest" .= G.GuestDescription (map (fmap describe) (checkedEntries bundle.guest)) (checkedModules bundle.guest)
  , "flows" .= map flowValue bundle.closure
  , "plugins" .= map pluginValue bundle.plugins
  , "model" .= fmap modelValue bundle.model ]
  where
    describe (InspectedSchema contract sources) = G.describeContract (descriptionOf contract) (metadataOf contract)
      (map (Text.pack . relativeName) sources)
    flowValue flow = case flow.declaration of
      FlowDeclaration (RecipeId ident) (FlowEntryRef entry) bindings -> object
        ["recipe" .= ident,"flow" .= entry,"bindings" .= bindings,"graph" .= flow.graph,"mermaid" .= flow.mermaid]
    modelValue (ModelConfiguration provider model credential) = object
      ["provider" .= object ["tag" .= show provider],"model" .= model,"credential" .= secretNameText credential]

programValue :: CompiledProgram -> Value
programValue (CompiledProgram (BuildIdentity digest system derivation output) executable retention) = object
  ["sources" .= Bytes.unpack digest,"system" .= system,"derivation" .= derivation,"output" .= output,
   "executable" .= executable,"retention" .= retention]
parseProgram :: Value -> Parser CompiledProgram
parseProgram = exactObject "captured program" ["sources","system","derivation","output","executable","retention"] $ \fields -> do
  digest <- Bytes.pack <$> fields .: "sources"
  system <- fields .: "system"
  derivation <- fields .: "derivation"
  output <- fields .: "output"
  executable <- fields .: "executable"
  retention <- fields .: "retention"
  _ <- either fail pure (directoryScope output)
  unless (executable == output ++ "/bin/kyyn-guest") (fail "Executable differs from pinned Nix output")
  pure (CompiledProgram (BuildIdentity digest system derivation output) executable retention)

pluginValue :: PreparedPlugin -> Value
pluginValue (PreparedPlugin (PreparedPackage name (PackageIdentity identity) connectors) instances) = object
  ["name" .= pluginNameText name,"identity" .= identity,
   "defaults" .= [object ["type" .= (coerce kind :: String),"value" .= value] |
      PreparedSinkConnector {connectorType = kind,sinkDefaultOptions = CheckedValue _ value} <- connectors],
   "instances" .= [object ["name" .= (coerce instanceName :: String),"binding" .= (coerce binding :: String),
      "type" .= (coerce (getField @"connectorType" connector) :: String),"config" .= value] |
      ConfiguredConnector instanceName binding connector (CheckedValue _ value) <- instances]]

parseBundle :: Value -> Parser FlowBundle
parseBundle = exactObject "execution bundle" ["revision","program","guest","flows","plugins","model"] $ \fields -> do
  revision <- fields .: "revision" >>= either fail pure . gitRevision
  program <- fields .: "program" >>= parseProgram
  guest <- fields .: "guest" >>= either (fail . show) pure . checkGuest
  flows <- fields .: "flows" >>= traverse (exactObject "captured flow" ["recipe","flow","bindings","graph","mermaid"] (\value -> do
    ident <- RecipeId <$> value .: "recipe"
    source <- value .: "flow"
    bindings <- value .: "bindings"
    let declaration = FlowDeclaration ident (FlowEntryRef source) bindings
    (entry,input,output) <- case [(entry,input.contract,output.contract) | entry <- compiledEntries program guest,
        G.InteractiveEntry _ actual (G.InteractiveContracts input output) <- [entryDescription entry], actual == source] of
      [match] -> pure match
      _ -> fail "Captured flow has no unique checked interactive entry"
    PreparedFlowEntry declaration entry input output <$> value .: "graph" <*> value .: "mermaid"))
  case flows of
    [] -> fail "Captured closure is empty"
    first:_ -> do
      let definitions = [Fact (FactId ident) (ClosedRecipe (Interactive bindings) source) |
            flow <- flows, FlowDeclaration (RecipeId ident) source bindings <- [flow.declaration]]
      resolved <- either (fail . show) pure (flowClosure definitions first.declaration.recipe)
      unless (resolved == map (.declaration) flows) (fail "Captured closure is incomplete or contains undeclared entries")
  plugins <- fields .: "plugins" >>= traverse (parsePlugin program guest)
  let names = [name | PreparedPlugin (PreparedPackage name _ _) _ <- plugins]
      bindings = [binding | PreparedPlugin _ instances <- plugins, ConfiguredConnector _ binding _ _ <- instances]
  unless (length names == length (nub names) && length bindings == length (nub bindings)) (fail "Duplicate captured plugin or binding")
  model <- fields .: "model" >>= traverse (either fail pure . decodeConfiguration)
  pure (FlowBundle revision program guest flows plugins model)
  where
    parsePlugin program guest = exactObject "captured plugin" ["name","identity","defaults","instances"] $ \fields -> do
      name <- fields .: "name" >>= either fail pure . pluginName
      identity <- PackageIdentity <$> fields .: "identity"
      defaults <- fields .: "defaults" >>= traverse (exactObject "sink defaults" ["type","value"] (\value ->
        (,) <$> (value .: "type" >>= either fail pure . connectorTypeName) <*> value .: "value"))
      unless (length defaults == length (nub (map fst defaults))) (fail "Duplicate captured sink defaults")
      connectors <- traverse (\connector -> do
        let owner = connectorIdentity connector
        kind <- either fail pure (connectorTypeName (Text.unpack owner.connectorType))
        either (fail . show) pure (connectorDescription connector (lookup kind defaults)))
        [connector | connector <- compiledConnectors program guest,
         (connectorIdentity connector).connectorPlugin == Text.pack (pluginNameText name)]
      unless (all (\(kind,_) -> any (\connector -> case connector of PreparedSinkConnector {connectorType = actual} -> actual == kind; _ -> False) connectors) defaults)
        (fail "Defaults reference an undeclared sink")
      instances <- fields .: "instances" >>= traverse (exactObject "captured connector instance" ["name","binding","type","config"] (\value -> do
        instanceName <- value .: "name" >>= either fail pure . connectorName
        binding <- value .: "binding" >>= either fail pure . bindingName
        kind <- value .: "type" >>= either fail pure . connectorTypeName
        connector <- case [c | c <- connectors, getField @"connectorType" c == kind] of
          [match] -> pure match
          _ -> fail "Captured instance has no unique connector"
        configuration <- value .: "config"
        pure (ConfiguredConnector instanceName binding connector (CheckedValue (contractId (getField @"configContract" connector)) configuration))))
      let instanceNames = [ident | ConfiguredConnector ident _ _ _ <- instances]
      unless (length instanceNames == length (nub instanceNames)) (fail "Duplicate captured connector instances")
      pure (PreparedPlugin (PreparedPackage name identity connectors) instances)
    connectorIdentity (CompiledSource identity _ _ _ _ _) = identity
    connectorIdentity (CompiledSink identity _ _ _ _) = identity

exactObject :: String -> [Key] -> (Keys.KeyMap Value -> Parser a) -> Value -> Parser a
exactObject label expected decode = withObject label $ \fields -> do
  unless (sort (Keys.keys fields) == sort expected) (fail (label ++ ": unexpected or missing fields"))
  decode fields
