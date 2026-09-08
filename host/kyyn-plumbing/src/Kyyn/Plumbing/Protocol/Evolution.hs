module Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, identityEvolutionSource, decodeEvolutionReply) where

import Control.Monad (unless)
import Data.List (nub, intercalate, sort)
import Data.Aeson (Value, Object, eitherDecodeStrict, withObject, withArray, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.Foldable (toList)
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract (RootContract, rootSchema, rootType, contractId, contractFingerprint)
import Kyyn.Domain.DataType (DataType(..), haskellType, definingModule, reachableTypes)
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.EvolutionReport (EvolutionObservation(..), StepObservation(..), ObservedRoot(..))
import Kyyn.Types.Evolution (EvolutionFailure(..), Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Diagnostic (ValidationReport(..))
import Kyyn.Plumbing.Protocol.Validation (parseReport)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (bindingModule)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

identityEvolutionSource :: ByteString
identityEvolutionSource = Text.encodeUtf8 (Text.pack (unlines
  [ "module Evolution where"
  , "import Kyyn.Evolution (EvolutionFailure, EvolutionOutput, evaluateEvolution, identityEvolution)"
  , "import Kyyn.Types.Program (Program)"
  , ""
  , "evolution :: root -> Program calls (Either EvolutionFailure (EvolutionOutput root))"
  , "evolution = pure . evaluateEvolution identityEvolution"
  ]))

evolutionBindings :: [(String, RootContract)] -> Either String FileTree
evolutionBindings declarations = do
  let names = map fst declarations
  unless (not (null names) && length names == length (nub names)) (Left "Evolution bindings must be nonempty and uniquely named")
  mapM_ (bindingModule . ("KyynEvolutionBindings." ++)) names
  codecs <- sequence [do
    source <- generateCodecs (codecName index) (rootType (rootSchema contract))
    path <- relativePath (codecName index ++ ".hs")
    pure (path,utf8 source) | (index,(_,contract)) <- zip [0..] declarations]
  path <- relativePath "KyynEvolutionBindings.hs"
  let source = unlines $
        ["module KyynEvolutionBindings (" ++ intercalate ", " names ++ ") where",
         "import Kyyn.Evolution.Internal (RootBinding(..))", "import Kyyn.Runtime.Json (encodeWith)"] ++
        ["import qualified " ++ name | name <- nub [definingModule name |
          (_,contract) <- declarations, Algebraic name _ _ <- reachableTypes (rootType (rootSchema contract))]] ++
        ["import qualified " ++ codecName index | (index,_) <- zip [0..] declarations] ++
        concat [[name ++ " :: RootBinding " ++ haskellType (rootType (rootSchema contract)),
          name ++ " = RootBinding " ++ show (contractFingerprint (contractId (rootSchema contract))) ++
          " (encodeWith " ++ codecName index ++ ".rootCodec)"] | (index,(name,contract)) <- zip [0..] declarations]
  fileTree ((path,utf8 source):codecs)
  where
    codecName :: Int -> String
    codecName index = "KyynEvolutionCodec" ++ show index
    utf8 = Text.encodeUtf8 . Text.pack

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
