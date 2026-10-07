module Kyyn.Plumbing.Protocol.RecipeEvolution
  ( recipeEvolutionBindings, recipeEvolutionSources, recipeEvolutionInput
  , decodeRecipeEvolutionReply, identityRecipeEvolutionSource
  ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=), (.:), withObject)
import qualified Data.Aeson.KeyMap as Keys
import Data.ByteString (ByteString)
import Data.List (nub, sort)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType (haskellType, typeModules, definingModule)
import Kyyn.Domain.EvolutionReport (EvolutionObservation)
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.Recipe (KnowledgeBase(..), ProposedRecipe(..), StoredRecipe(..), proposedRecipe)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Curation (RecipeId(..))
import Kyyn.Types.Evolution (EvolutionFailure)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)
import Kyyn.Plumbing.Protocol.Evolution (domainCollectionBindings, decodeEvolutionReplyWith)
import Kyyn.Plumbing.Protocol.FactEdits (factEditBindings)

identityRecipeEvolutionSource :: String -> ByteString
identityRecipeEvolutionSource selected = utf8 $ unlines
  ["{-# LANGUAGE OverloadedStrings #-}",
   "module Evolution where", "import Kyyn.Workspace.Evolution",
   "import qualified " ++ definingModule selected ++ " as Before",
   "import qualified Kyyn.Workspace.Before as BeforeCollections",
   "",
   "evolution :: RecipeEvolution Root RecipeState", "evolution = identityEvolution"]

recipeEvolutionBindings :: RootContract -> CheckedContract -> Either String FileTree
recipeEvolutionBindings domain state = do
  edits <- factEditBindings domain
  collections <- traverse (`domainCollectionBindings` domain) ["Before","After"]
  rootCodec <- generateCodecs "KyynRecipeFactsCodec" (rootType (rootSchema domain))
  stateCodec <- generateCodecs "KyynRecipeStateCodec" (rootType state)
  let root = haskellType (rootType (rootSchema domain))
      selectedState = haskellType (rootType state)
      imports = ["import qualified " ++ name | name <- nub
        (typeModules (rootType (rootSchema domain)) ++ typeModules (rootType state))]
      codec = unlines $ ["module KyynRecipeRootCodec (rootCodec) where",
        "import Kyyn.Runtime.Json", "import qualified KyynRecipeFactsCodec as Facts",
        "import qualified KyynRecipeStateCodec as State"] ++ imports ++
        ["rootCodec :: Codec (" ++ root ++ ", " ++ selectedState ++ ")",
         "rootCodec = Codec encode decode", "  where",
         "    encode (facts,state) = record [(\"facts\",encodeWith Facts.rootCodec facts),(\"state\",encodeWith State.rootCodec state)]",
         "    decode value = do", "      values <- fields [\"facts\",\"state\"] value",
         "      (,) <$> field \"facts\" Facts.rootCodec values <*> field \"state\" State.rootCodec values"]
      facade = unlines $ ["{-# LANGUAGE OverloadedStrings #-}",
        "module Kyyn.Workspace.Evolution (module Kyyn.Recipe, module Kyyn.Edit, Rationale(..), EvidenceRef(..), (>=>), identityEvolution, Root, RecipeState, recipeEdit) where",
        "import Kyyn.Recipe", "import Kyyn.Edit", "import Kyyn.Evolution (Rationale(..), EvidenceRef(..), (>=>), identityEvolution)",
        "import qualified Kyyn.Evolution.Internal as Internal", "import Kyyn.Runtime.Json (encodeWith)",
        "import qualified KyynRecipeRootCodec"] ++ imports ++
        ["type Root = " ++ root, "type RecipeState = " ++ selectedState,
         "-- | Edit domain facts and the selected recipe's state in one recorded step.",
         "recipeEdit :: Rationale -> RecipeEdit Root RecipeState () -> RecipeEvolution Root RecipeState",
         "recipeEdit = Internal.edit (Internal.RootBinding " ++ show (contractFingerprint (contractId (rootSchema domain))) ++
           " (encodeWith KyynRecipeRootCodec.rootCodec))"]
  generated <- traverse (\(name,contents) -> (,utf8 contents) <$> relativePath name)
    [("KyynRecipeFactsCodec.hs",rootCodec),("KyynRecipeStateCodec.hs",stateCodec),
     ("KyynRecipeRootCodec.hs",codec),("Kyyn/Workspace/Evolution.hs",facade)]
  fileTree (generated ++ concatMap files collections ++ files edits)

recipeEvolutionSources :: RootContract -> CheckedContract -> FileTree -> Either String GuestSources
recipeEvolutionSources root state authored = do
  bindings <- recipeEvolutionBindings root state
  entry <- relativePath "KyynEvolutionEntry.hs"
  let source = unlines
        ["module KyynEvolutionEntry where", "import qualified Evolution", "import Kyyn.Workspace.Evolution",
         "import Kyyn.Runtime.Evolution", "import Kyyn.Evolution.Internal (evaluateEvolution, EvolutionOutput)",
         "import Kyyn.Types.Evolution (EvolutionFailure)", "import Kyyn.Types.Program (Program)",
         "import qualified KyynRecipeRootCodec as Codec",
         "import Kyyn.Runtime.Transport (withTransport, readJson, writeValue)",
         "selected :: (Root, RecipeState) -> Program NoRequests (Either EvolutionFailure (EvolutionOutput (Root, RecipeState)))",
         "selected = pure . evaluateEvolution Evolution.evolution", "main :: IO ()",
         "main = withTransport $ \\transport -> do", "  input <- readJson transport",
         "  output <- either fail pure (executeEvolution Codec.rootCodec Codec.rootCodec selected input)",
         "  writeValue transport output"]
  guestSources entry (files authored ++ files bindings ++ [(entry,utf8 source)])

recipeEvolutionInput :: Value -> StoredRecipe -> Value
recipeEvolutionInput facts (StoredRecipe _ _ _ (CheckedValue _ state)) = object ["facts" .= facts,"state" .= state]

decodeRecipeEvolutionReply :: RecipeId -> [Fact StoredRecipe] -> ByteString
  -> Either String (Either EvolutionFailure EvolutionObservation)
decodeRecipeEvolutionReply (RecipeId selected) recipes = decodeEvolutionReplyWith $ withObject "Recipe root" $ \fields -> do
  unless (sort (Keys.keys fields) == ["facts","state"]) (fail "Expected facts and recipe state")
  unless (length [() | Fact (FactId name) _ <- recipes, name == selected] == 1)
    (fail "Selected recipe is missing or ambiguous")
  facts <- fields .: "facts"
  next <- fields .: "state"
  let replace (Fact ident@(FactId name) recipe) = Fact ident $ case proposedRecipe recipe of
        ProposedRecipe method stateType contract state -> ProposedRecipe method stateType contract
          (if name == selected then next else state)
  pure (KnowledgeBase facts (map replace recipes))

utf8 :: String -> ByteString
utf8 = Text.encodeUtf8 . Text.pack
