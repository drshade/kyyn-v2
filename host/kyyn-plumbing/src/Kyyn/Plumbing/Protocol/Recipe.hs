module Kyyn.Plumbing.Protocol.Recipe (recipeDescriptionSources, recipeSources, recipeInputValue) where

import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Aeson (Value, object, (.=))
import Kyyn.Domain.Contract (RootContract, rootSchema, rootType)
import Kyyn.Domain.DataType (DataType(..))
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.Recipe (DescriptionFormat(..), RecipeSignature(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings)
import Kyyn.Plumbing.Protocol.FactEdits (factEditType)
import Kyyn.Plumbing.Protocol.Tool (ConnectorInterface, InstanceBinding, toolBindings, toolSourcesWithCodecs)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources, bindingModule)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

recipeDescriptionSources :: RootContract -> FlowEntryRef -> DescriptionFormat -> FileTree -> Either String GuestSources
recipeDescriptionSources contract entry format = recipeProjectionSources
  ["import qualified Agentic.Describe as Describe", "import qualified Data.Text as Text",
   "import Kyyn.Runtime.Json (encodeWith, stringCodec, printValue)",
   "import Kyyn.Runtime.Transport (withTransport, writeJson)"]
  ["main = withTransport $ \\transport -> either fail (writeJson transport) (printValue (encodeWith stringCodec (Text.unpack (Describe." ++ renderer ++ " (Describe.describe selected)))))"]
  contract entry
  where renderer = case format of Tree -> "renderTree"; Dot -> "dot"; Mermaid -> "mermaid"

recipeProjectionSources :: [String] -> [String] -> RootContract -> FlowEntryRef -> FileTree -> Either String GuestSources
recipeProjectionSources imports body contract (FlowEntryRef entryText) sources = do
  let entry = Text.unpack entryText
  selectedModule <- bindingModule entry
  bindings <- evolutionBindings contract contract
  path <- relativePath "KyynRecipeCheck.hs"
  let source = unlines $
        [ "module KyynRecipeCheck where"
        , "import qualified " ++ selectedModule
        ] ++ imports ++
        [ "selected = " ++ entry
        , "main :: IO ()"
        ] ++ body
  guestSources path (files sources ++ files bindings ++ [(path,Text.encodeUtf8 (Text.pack source))])

recipeSources :: RootContract -> RecipeSignature -> FlowEntryRef -> [ConnectorInterface] -> [InstanceBinding] -> FileTree
  -> Either String GuestSources
recipeSources contract (RecipeSignature _ request state) (FlowEntryRef entryText) interfaces instances sources = do
  let entry = Text.unpack entryText
  selectedModule <- bindingModule entry
  bindings <- evolutionBindings contract contract
  generated <- toolBindings interfaces instances
  path <- relativePath "KyynRecipeFlow.hs"
  codecs <- traverse (\(name,kind) -> do
    code <- generateCodecs name kind
    location <- relativePath (name ++ ".hs")
    pure (location,Text.encodeUtf8 (Text.pack code)))
    [("KyynRecipeRequestCodec",request),("KyynRecipeStateCodec",state)]
  let root = rootType (rootSchema contract)
      input = Algebraic "Kyyn.Recipe.RecipeInput" [root,request,state] []
      output = Algebraic "Kyyn.Evolution.Proposal.RecipeProposal" [factEditType contract,state] []
      wrapper = unlines
        ["module KyynRecipeFlow where", "import qualified " ++ selectedModule,
         "import Kyyn.Agentic (interpret)", "selected = interpret " ++ entry]
      inputCodec = unlines
        ["module KyynToolInputCodec where", "import Kyyn.Runtime.Recipe (recipeInputCodec)",
         "import qualified KyynEvolutionCodec0", "import qualified KyynRecipeRequestCodec", "import qualified KyynRecipeStateCodec",
         "rootCodec = recipeInputCodec KyynEvolutionCodec0.rootCodec KyynRecipeRequestCodec.rootCodec KyynRecipeStateCodec.rootCodec"]
      outputCodec = unlines
        ["module KyynToolResultCodec where", "import Kyyn.Runtime.Proposal (recipeProposalCodec)",
         "import qualified KyynFactEditCodec", "import qualified KyynRecipeStateCodec",
         "rootCodec = recipeProposalCodec KyynFactEditCodec.rootCodec KyynRecipeStateCodec.rootCodec"]
  toolSourcesWithCodecs interfaces instances input output "KyynRecipeFlow.selected" inputCodec outputCodec
    (filter (\(name,_) -> name `notElem` map fst generated) (files sources)
      ++ files bindings ++ codecs ++ [(path,Text.encodeUtf8 (Text.pack wrapper))])

recipeInputValue :: Value -> Value -> Value -> Value
recipeInputValue root input state = object ["root" .= root,"input" .= input,"state" .= state]
