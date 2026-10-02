module Kyyn.Plumbing.Protocol.Recipe (recipeCheckSources, recipeSources, recipeInputValue) where

import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Aeson (Value, object, (.=))
import Kyyn.Domain.Contract (RootContract, rootSchema, rootType, collectionContracts)
import Kyyn.Domain.DataType (DataType(..), haskellType, definingModule)
import Kyyn.Domain.Curation (PendingEvidence(..), RecipeId(..))
import Kyyn.Domain.Evidence (EvidenceSnapshotRef(..), ConnectorInstanceRef(..), FetchId(..), EvidenceId(..))
import Kyyn.Domain.Plugin (pluginNameText)
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings)
import Kyyn.Plumbing.Protocol.FactEdits (factEditType)
import Kyyn.Plumbing.Protocol.Tool (ConnectorInterface, InstanceBinding, toolBindings, toolSourcesWithCodecs)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources, bindingModule)

recipeCheckSources :: RootContract -> FlowEntryRef -> FileTree -> Either String GuestSources
recipeCheckSources contract (FlowEntryRef entry) sources = do
  if null (collectionContracts (rootSchema contract))
    then Left "Closed recipes need at least one domain fact collection"
    else pure ()
  selectedModule <- bindingModule entry
  bindings <- evolutionBindings contract contract
  path <- relativePath "KyynRecipeCheck.hs"
  let root = haskellType (rootType (rootSchema contract))
      source = unlines
        [ "module KyynRecipeCheck where"
        , "import qualified " ++ selectedModule
        , "import qualified " ++ definingModule root
        , "import Kyyn.Agentic (Flow)"
        , "import Kyyn.Recipe (RecipeInput, ProposedCuration)"
        , "import Kyyn.Workspace.FactEdits (RootEdit)"
        , "selected :: Flow (RecipeInput " ++ root ++ ") (ProposedCuration RootEdit)"
        , "selected = " ++ entry
        , "main :: IO ()"
        , "main = pure ()"
        ]
  guestSources path (files sources ++ files bindings ++ [(path,Text.encodeUtf8 (Text.pack source))])

recipeSources :: RootContract -> FlowEntryRef -> [ConnectorInterface] -> [InstanceBinding] -> FileTree
  -> Either String GuestSources
recipeSources contract (FlowEntryRef entry) interfaces instances sources = do
  selectedModule <- bindingModule entry
  bindings <- evolutionBindings contract contract
  generated <- toolBindings interfaces instances
  path <- relativePath "KyynRecipeFlow.hs"
  let root = rootType (rootSchema contract)
      input = Algebraic "Kyyn.Recipe.RecipeInput" [root] []
      output = Algebraic "Kyyn.Evolution.Proposal.ProposedCuration" [factEditType contract] []
      wrapper = unlines
        ["module KyynRecipeFlow where", "import qualified " ++ selectedModule,
         "import Kyyn.Agentic (interpret)", "selected = interpret " ++ entry]
      inputCodec = unlines
        ["module KyynToolInputCodec where", "import Kyyn.Runtime.Recipe (recipeInputCodec)",
         "import qualified KyynEvolutionCodec0", "rootCodec = recipeInputCodec KyynEvolutionCodec0.rootCodec"]
      outputCodec = unlines
        ["module KyynToolResultCodec where", "import Kyyn.Runtime.Proposal (proposalCodec)",
         "import qualified KyynFactEditCodec", "rootCodec = proposalCodec KyynFactEditCodec.rootCodec"]
  toolSourcesWithCodecs interfaces instances input output "KyynRecipeFlow.selected" inputCodec outputCodec
    (filter (\(name,_) -> name `notElem` map fst generated) (files sources)
      ++ files bindings ++ [(path,Text.encodeUtf8 (Text.pack wrapper))])

recipeInputValue :: RecipeId -> Value -> [PendingEvidence] -> Value
recipeInputValue (RecipeId name) root pending = object
  ["recipe" .= name,"root" .= root,"pending" .= map selected pending]
  where
    selected (PendingEvidence snapshot changes) = batch snapshot "Changes"
      [object ["tag" .= show kind,"value" .= item] | (EvidenceId item,kind) <- changes]
    selected (Reconciliation snapshot ids) = batch snapshot "Reconciliation"
      [Text.pack item | EvidenceId item <- ids]
    batch (EvidenceSnapshotRef (ConnectorInstanceRef plugin instanceName) _ (FetchId fetch)) (kind :: String) values = object
      ["scope" .= object ["plugin" .= pluginNameText plugin,"instance" .= instanceName,"fetch" .= fetch],
       "batch" .= object ["tag" .= kind,"value" .= values]]
