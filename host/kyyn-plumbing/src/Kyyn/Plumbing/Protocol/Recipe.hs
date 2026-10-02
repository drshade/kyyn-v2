module Kyyn.Plumbing.Protocol.Recipe (recipeCheckSources) where

import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract (RootContract, rootSchema, rootType, collectionContracts)
import Kyyn.Domain.DataType (haskellType, definingModule)
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings)
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
