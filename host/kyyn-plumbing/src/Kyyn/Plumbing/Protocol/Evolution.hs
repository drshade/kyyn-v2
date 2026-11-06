module Kyyn.Plumbing.Protocol.Evolution
  ( identityEvolutionSource, decodeEvolutionReply, decodeEvolutionReplyWith ) where

import Control.Monad (unless)
import Data.List (sort)
import Data.Aeson (Value, Object, eitherDecodeStrict, withObject, withArray, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.Foldable (toList)
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.DataType (definingModule)
import Kyyn.Domain.EvolutionReport (EvolutionObservation(..), StepObservation(..), ObservedRoot(..))
import Kyyn.Domain.Recipe (KnowledgeBase, ProposedRecipe)
import Kyyn.Types.Evolution (EvolutionFailure(..), Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Diagnostic (ValidationReport(..))
import Kyyn.Plumbing.Protocol.Validation (parseReport)
import Kyyn.Plumbing.Protocol.Recipes (parseKnowledgeBase)

identityEvolutionSource :: String -> ByteString
identityEvolutionSource selected = Text.encodeUtf8 (Text.pack (unlines
  [ "{-# LANGUAGE OverloadedStrings #-}"
  , "module Evolution where"
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

decodeEvolutionReply :: ByteString -> Either String (Either EvolutionFailure EvolutionObservation)
decodeEvolutionReply = decodeEvolutionReplyWith parseKnowledgeBase

decodeEvolutionReplyWith :: (Value -> Parser (KnowledgeBase Value ProposedRecipe))
  -> ByteString -> Either String (Either EvolutionFailure EvolutionObservation)
decodeEvolutionReplyWith parseRoot bytes = eitherDecodeStrict bytes >>= parseEither
  (exact "EvolutionReply" ["tag","value"] $ \o -> do
    tag <- o .: "tag"
    value <- o .: "value"
    case tag :: String of
      "Rejected" -> do
        ValidationReport diagnostics <- parseReport value
        pure (Left (EvolutionFailure diagnostics))
      "Succeeded" -> Right <$> exact "EvolutionOutput" ["after","steps"] (\output ->
        EvolutionObservation <$> (output .: "after" >>= parseRoot) <*> (output .: "steps" >>= array step)) value
      _ -> fail "Unknown evolution outcome")
  where
    step = exact "StepObservation" ["rationale","before","after"] $ \o ->
      StepObservation <$> (o .: "rationale" >>= rationale) <*> (o .: "before" >>= root) <*> (o .: "after" >>= root)
    root = exact "ObservedRoot" ["contract","value"] $ \o -> ObservedRoot <$> o .: "contract" <*> (o .: "value" >>= parseRoot)
    rationale = exact "Rationale" ["explanation","evidence"] $ \o ->
      Rationale <$> o .: "explanation" <*> (o .: "evidence" >>= array evidence)
    evidence = exact "EvidenceRef" ["producer","connector","source","externalReferences"] $ \o ->
      EvidenceRef <$> o .: "producer" <*> o .: "connector" <*> o .: "source" <*> o .: "externalReferences"
    array parse = withArray "List" (traverse parse . toList)

exact :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
exact label expected parse = withObject label $ \o -> do
  unless (sort (Keys.keys o) == sort expected) (fail (label ++ ": unexpected or missing fields"))
  parse o
