module Kyyn.Plumbing.Protocol.Evolution
  ( evolutionBindings, identityEvolutionSource, decodeEvolutionReply, evolutionSources, mergeEvolutionSources ) where

import Control.Monad (unless)
import Data.List (nub, sort)
import Data.Aeson (Value, Object, eitherDecodeStrict, withObject, withArray, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.Foldable (toList)
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract (RootContract, rootSchema, rootType, contractId, contractFingerprint, collectionContracts, CollectionContract(..))
import Kyyn.Domain.DataType (DataType(..), haskellType, definingModule, typeModules)
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.EvolutionReport (EvolutionObservation(..), StepObservation(..), ObservedRoot(..))
import Kyyn.Types.Evolution (EvolutionFailure(..), Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Diagnostic (ValidationReport(..))
import Kyyn.Plumbing.Protocol.Validation (parseReport)
import Kyyn.Plumbing.Protocol.Curation (parseCuration)
import Kyyn.Plumbing.Protocol.Recipes (parseKnowledgeBase)
import Kyyn.Plumbing.Protocol.FactEdits (factEditBindings)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

identityEvolutionSource :: String -> ByteString
identityEvolutionSource selected = Text.encodeUtf8 (Text.pack (unlines
  [ "module Evolution where"
  , "import Kyyn.Workspace.Evolution"
  , "import qualified " ++ selectedModule ++ " as Before"
  , "import qualified " ++ selectedModule ++ " as After"
  , "import qualified Kyyn.Workspace.Before as BeforeCollections"
  , "import qualified Kyyn.Workspace.After as AfterCollections"
  , ""
  , "evolution :: Evolution (KnowledgeBase " ++ aliased "Before" ++ ") (KnowledgeBase " ++ aliased "After" ++ ")"
  , "evolution = identityEvolution"
  ]))
  where
    selectedModule = definingModule selected
    aliased name = name ++ "." ++ drop (length selectedModule + 1) selected

mergeEvolutionSources :: [FileTree] -> Either String FileTree
mergeEvolutionSources trees = case fileTree (nub (concatMap files trees)) of
  Left message -> Left (message ++ "; give changed schema modules distinct names (for example SchemaV1 and SchemaV2), with qualified imports for readability")
  Right tree -> Right tree

evolutionSources :: RootContract -> RootContract -> FileTree -> Either String GuestSources
evolutionSources before after authored = do
  bindings <- evolutionBindings before after
  entryPath <- relativePath "KyynEvolutionEntry.hs"
  let beforeType = rootType (rootSchema before)
      afterType = rootType (rootSchema after)
      entry = unlines $
        ["module KyynEvolutionEntry where", "import qualified Evolution"] ++
        ["import qualified " ++ name | name <- nub (concatMap typeModules [beforeType,afterType])] ++
        ["import qualified KyynEvolutionCodec0 as BeforeCodec", "import qualified KyynEvolutionCodec1 as AfterCodec",
         "import Kyyn.Runtime.Evolution", "import Kyyn.Evolution (EvolutionFailure, KnowledgeBase)",
         "import Kyyn.Evolution.Internal (EvolutionOutput, evaluateEvolution)",
         "import Kyyn.Types.Program (Program)",
         "import Kyyn.Runtime.Transport (withTransport, readJson, writeJson)",
         "selected :: KnowledgeBase " ++ haskellType beforeType ++ " -> Program NoRequests (Either EvolutionFailure (EvolutionOutput (KnowledgeBase " ++ haskellType afterType ++ ")))",
         "selected = pure . evaluateEvolution Evolution.evolution", "main :: IO ()", "main = withTransport $ \\transport -> do", "  input <- readJson transport",
         "  output <- either fail pure (executeEvolution (knowledgeBaseCodec BeforeCodec.rootCodec) (knowledgeBaseCodec AfterCodec.rootCodec) selected input)",
         "  writeJson transport output"]
  guestSources entryPath (files authored ++ files bindings ++ [(entryPath,Text.encodeUtf8 (Text.pack entry))])

evolutionBindings :: RootContract -> RootContract -> Either String FileTree
evolutionBindings before after = do
  collections <- sequence [collectionBindings "Before" before, collectionBindings "After" after]
  proposals <- if contractId (rootSchema before) == contractId (rootSchema after)
      && not (null (collectionContracts (rootSchema after)))
    then factEditBindings after
    else fileTree []
  codecs <- sequence [do
    source <- generateCodecs (codecName index) (rootType (rootSchema contract))
    path <- relativePath (codecName index ++ ".hs")
    pure (path,utf8 source) | (index,(_,contract)) <- zip [0..] declarations]
  path <- relativePath "Kyyn/Workspace/Evolution.hs"
  let source = unlines $
        ["module Kyyn.Workspace.Evolution (module Kyyn.Evolution, editBefore, evolve, edit) where",
         "import Kyyn.Evolution",
         "import Kyyn.Evolution.Internal (RootBinding(..))",
         "import qualified Kyyn.Evolution.Internal as Internal", "import Kyyn.Runtime.Json (encodeWith)",
         "import Kyyn.Runtime.Evolution (knowledgeBaseCodec)"] ++
        ["import qualified " ++ name | name <- nub (concatMap (typeModules . rootType . rootSchema . snd) declarations)] ++
        ["import qualified " ++ codecName index | (index,_) <- zip [0..] declarations] ++
        concat [[name ++ " :: RootBinding (KnowledgeBase " ++ haskellType (rootType (rootSchema contract)) ++ ")",
          name ++ " = RootBinding " ++ show (contractFingerprint (contractId (rootSchema contract))) ++
          " (encodeWith (knowledgeBaseCodec " ++ codecName index ++ ".rootCodec))"] | (index,(name,contract)) <- zip [0..] declarations] ++
        ["-- | Transform the Before root, " ++ beforeType ++ ", into the After root, " ++ afterType ++ ".",
         "-- The supplied rationale describes one recorded step and its diff.",
         "evolve :: Rationale -> (" ++ beforeType ++ " -> Either EvolutionFailure " ++ afterType ++ ") -> Evolution " ++ beforeType ++ " " ++ afterType,
         "evolve = Internal.evolve beforeRoot afterRoot"] ++
        concat [["-- | Edit the " ++ role ++ " root, " ++ endpoint ++ ", without changing its schema.",
                 "-- The supplied rationale describes one recorded step and its diff.",
                 name ++ " :: Rationale -> Edit " ++ endpoint ++ " () -> Evolution " ++ endpoint ++ " " ++ endpoint,
                 name ++ " = Internal.edit " ++ binding] |
          (name,binding,endpoint,role) <- [("editBefore","beforeRoot",beforeType,"Before"),("edit","afterRoot",afterType,"After")]]
  fileTree ((path,utf8 source):codecs ++ concatMap files collections ++ files proposals)
  where
    declarations = [("beforeRoot",before),("afterRoot",after)]
    beforeType = "(KnowledgeBase " ++ haskellType (rootType (rootSchema before)) ++ ")"
    afterType = "(KnowledgeBase " ++ haskellType (rootType (rootSchema after)) ++ ")"
    codecName :: Int -> String
    codecName index = "KyynEvolutionCodec" ++ show index
    utf8 = Text.encodeUtf8 . Text.pack

collectionBindings :: String -> RootContract -> Either String FileTree
collectionBindings endpoint contract = do
  path <- relativePath ("Kyyn/Workspace/" ++ endpoint ++ ".hs")
  let root = rootType (rootSchema contract)
      declarations = collectionContracts (rootSchema contract)
      rootModule = case root of Algebraic name _ _ -> definingModule name; _ -> error "Checked root is not a record"
      source = unlines $
        ["module Kyyn.Workspace." ++ endpoint ++ " (" ++ comma [field | CollectionContract _ field _ _ <- declarations] ++ ") where",
         "import Kyyn.Edit (Collection)", "import Kyyn.Evolution (KnowledgeBase, facts)",
         "import qualified Kyyn.Edit.Internal as Internal", "import qualified Kyyn.Optics as Optics"] ++
        ["import qualified " ++ name | name <- typeModules root] ++
        concat [["-- | Collection " ++ show name ++ " in " ++ haskellType root ++ ".",
                 "-- Root field: " ++ field ++ "; fact type: " ++ haskellType payload ++ ".",
                 field ++ " :: Collection (KnowledgeBase " ++ haskellType root ++ ") " ++ haskellType payload,
                 field ++ " = Internal.Collection " ++ show name ++ " (facts . Optics.lens " ++ rootModule ++ "." ++ field ++
                   " (\\root value -> root { " ++ rootModule ++ "." ++ field ++ " = value }))"] |
          CollectionContract name field payload _ <- declarations]
  fileTree [(path,Text.encodeUtf8 (Text.pack source))]
  where
    comma [] = ""
    comma [x] = x
    comma (x:xs) = x ++ ", " ++ comma xs

decodeEvolutionReply :: ByteString -> Either String (Either EvolutionFailure EvolutionObservation)
decodeEvolutionReply bytes = eitherDecodeStrict bytes >>= parseEither
  (exact "EvolutionReply" ["tag","value"] $ \o -> do
    tag <- o .: "tag"
    value <- o .: "value"
    case tag :: String of
      "Rejected" -> do
        ValidationReport diagnostics <- parseReport value
        pure (Left (EvolutionFailure diagnostics))
      "Succeeded" -> Right <$> exact "EvolutionOutput" ["after","steps","curation"] (\output ->
        EvolutionObservation <$> (output .: "after" >>= parseKnowledgeBase) <*> (output .: "steps" >>= array step)
          <*> (output .: "curation" >>= parseCuration)) value
      _ -> fail "Unknown evolution outcome")
  where
    step = exact "StepObservation" ["rationale","before","after"] $ \o ->
      StepObservation <$> (o .: "rationale" >>= rationale) <*> (o .: "before" >>= root) <*> (o .: "after" >>= root)
    root = exact "ObservedRoot" ["contract","value"] $ \o -> ObservedRoot <$> o .: "contract" <*> (o .: "value" >>= parseKnowledgeBase)
    rationale = exact "Rationale" ["explanation","evidence"] $ \o ->
      Rationale <$> o .: "explanation" <*> (o .: "evidence" >>= array evidence)
    evidence = exact "EvidenceRef" ["producer","connector","source","references"] $ \o ->
      EvidenceRef <$> o .: "producer" <*> o .: "connector" <*> o .: "source" <*> o .: "references"
    array parse = withArray "List" (traverse parse . toList)

exact :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
exact label expected parse = withObject label $ \o -> do
  unless (sort (Keys.keys o) == sort expected) (fail (label ++ ": unexpected or missing fields"))
  parse o
