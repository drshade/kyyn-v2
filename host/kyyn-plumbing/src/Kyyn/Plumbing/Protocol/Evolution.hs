module Kyyn.Plumbing.Protocol.Evolution
  ( evolutionBindings, identityEvolutionSource, decodeEvolutionReply, evolutionSources ) where

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
import Kyyn.Domain.DataType (DataType(..), haskellType, definingModule, reachableTypes)
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.EvolutionReport (EvolutionObservation(..), StepObservation(..), ObservedRoot(..))
import Kyyn.Types.Evolution (EvolutionFailure(..), Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Diagnostic (ValidationReport(..))
import Kyyn.Plumbing.Protocol.Validation (parseReport)
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
  , "evolution :: Evolution " ++ aliased "Before" ++ " " ++ aliased "After"
  , "evolution = identityEvolution"
  ]))
  where
    selectedModule = definingModule selected
    aliased name = name ++ "." ++ drop (length selectedModule + 1) selected

evolutionSources :: RootContract -> RootContract -> FileTree -> Either String GuestSources
evolutionSources before after authored = do
  bindings <- evolutionBindings before after
  entryPath <- relativePath "KyynEvolutionEntry.hs"
  let beforeType = rootType (rootSchema before)
      afterType = rootType (rootSchema after)
      entry = unlines $
        ["module KyynEvolutionEntry where", "import qualified Evolution"] ++
        ["import qualified " ++ name | name <- nub [definingModule name |
          t <- [beforeType,afterType], Algebraic name _ _ <- reachableTypes t]] ++
        ["import qualified KyynEvolutionCodec0 as BeforeCodec", "import qualified KyynEvolutionCodec1 as AfterCodec",
         "import Kyyn.Runtime.Evolution", "import Kyyn.Evolution (EvolutionFailure)",
         "import Kyyn.Evolution.Internal (EvolutionOutput, evaluateEvolution)",
         "import Kyyn.Types.Program (Program)",
         "selected :: " ++ haskellType beforeType ++ " -> Program NoRequests (Either EvolutionFailure (EvolutionOutput " ++ haskellType afterType ++ "))",
         "selected = pure . evaluateEvolution Evolution.evolution", "main :: IO ()", "main = do", "  input <- getContents",
         "  output <- either fail pure (executeEvolution BeforeCodec.rootCodec AfterCodec.rootCodec selected input)",
         "  putStrLn output"]
  guestSources entryPath (files authored ++ files bindings ++ [(entryPath,Text.encodeUtf8 (Text.pack entry))])

evolutionBindings :: RootContract -> RootContract -> Either String FileTree
evolutionBindings before after = do
  collections <- sequence [collectionBindings "Before" before, collectionBindings "After" after]
  codecs <- sequence [do
    source <- generateCodecs (codecName index) (rootType (rootSchema contract))
    path <- relativePath (codecName index ++ ".hs")
    pure (path,utf8 source) | (index,(_,contract)) <- zip [0..] declarations]
  path <- relativePath "Kyyn/Workspace/Evolution.hs"
  let source = unlines $
        ["module Kyyn.Workspace.Evolution (module Kyyn.Evolution, editBefore, evolve, edit) where",
         "import Kyyn.Evolution",
         "import Kyyn.Evolution.Internal (RootBinding(..))",
         "import qualified Kyyn.Evolution.Internal as Internal", "import Kyyn.Runtime.Json (encodeWith)"] ++
        ["import qualified " ++ name | name <- nub [definingModule name |
          (_,contract) <- declarations, Algebraic name _ _ <- reachableTypes (rootType (rootSchema contract))]] ++
        ["import qualified " ++ codecName index | (index,_) <- zip [0..] declarations] ++
        concat [[name ++ " :: RootBinding " ++ haskellType (rootType (rootSchema contract)),
          name ++ " = RootBinding " ++ show (contractFingerprint (contractId (rootSchema contract))) ++
          " (encodeWith " ++ codecName index ++ ".rootCodec)"] | (index,(name,contract)) <- zip [0..] declarations] ++
        ["evolve :: Rationale -> (" ++ beforeType ++ " -> Either EvolutionFailure " ++ afterType ++ ") -> Evolution " ++ beforeType ++ " " ++ afterType,
         "evolve = Internal.evolve beforeRoot afterRoot"] ++
        concat [[name ++ " :: Rationale -> Edit " ++ endpoint ++ " () -> Evolution " ++ endpoint ++ " " ++ endpoint,
                 name ++ " = Internal.edit " ++ binding] |
          (name,binding,endpoint) <- [("editBefore","beforeRoot",beforeType),("edit","afterRoot",afterType)]]
  fileTree ((path,utf8 source):codecs ++ concatMap files collections)
  where
    declarations = [("beforeRoot",before),("afterRoot",after)]
    beforeType = haskellType (rootType (rootSchema before))
    afterType = haskellType (rootType (rootSchema after))
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
         "import qualified Kyyn.Edit.Internal as Internal", "import qualified Kyyn.Optics as Optics"] ++
        ["import qualified " ++ name | name <- nub [definingModule name | Algebraic name _ _ <- reachableTypes root]] ++
        concat [[field ++ " :: Internal.Collection " ++ haskellType root ++ " (" ++ haskellType payload ++ ")",
                 field ++ " = Internal.Collection " ++ show name ++ " (Optics.lens " ++ rootModule ++ "." ++ field ++
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
      "Succeeded" -> Right <$> exact "EvolutionOutput" ["after","steps"] (\output ->
        EvolutionObservation <$> output .: "after" <*> (output .: "steps" >>= array step)) value
      _ -> fail "Unknown evolution outcome")
  where
    step = exact "StepObservation" ["rationale","before","after"] $ \o ->
      StepObservation <$> (o .: "rationale" >>= rationale) <*> (o .: "before" >>= root) <*> (o .: "after" >>= root)
    root = exact "ObservedRoot" ["contract","value"] $ \o -> ObservedRoot <$> o .: "contract" <*> o .: "value"
    rationale = exact "Rationale" ["explanation","evidence"] $ \o ->
      Rationale <$> o .: "explanation" <*> (o .: "evidence" >>= array evidence)
    evidence = exact "EvidenceRef" ["producer","connector","source","references"] $ \o ->
      EvidenceRef <$> o .: "producer" <*> o .: "connector" <*> o .: "source" <*> o .: "references"
    array parse = withArray "List" (traverse parse . toList)

exact :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
exact label expected parse = withObject label $ \o -> do
  unless (sort (Keys.keys o) == sort expected) (fail (label ++ ": unexpected or missing fields"))
  parse o
