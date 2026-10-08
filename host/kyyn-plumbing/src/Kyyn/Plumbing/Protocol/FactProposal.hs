module Kyyn.Plumbing.Protocol.FactProposal
  ( proposalShape, proposalValue, parseProposal, proposalChange, lowerProposal ) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value, object, (.=), (.:), withObject, encode)
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FactProposal
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Protocol.FactEdits (factEditType)

proposalShape :: RootContract -> CheckedContract -> Either String Shape
proposalShape contract state = do
  edits <- if null (collectionContracts (rootSchema contract)) then pure (List (Union []))
    else shapeOf (ListType (factEditType contract))
  pure (Record [("steps",List (Record [("rationale",rationale),("edits",edits)])),("state",contractShape state)])
  where
    text = Scalar TextScalar
    rationale = Record [("explanation",text),("evidence",List (Record
      [("producer",text),("connector",text),("source",text),("externalReferences",List text)]))]

proposalValue :: FactProposal -> Value
proposalValue (FactProposal steps (CheckedValue _ state)) = object
  ["steps" .= map step steps,"state" .= state]
  where
    step (FactProposalStep (Rationale explanation evidence) edits) = object
      ["rationale" .= object ["explanation" .= explanation,"evidence" .= map citation evidence],"edits" .= edits]
    citation (EvidenceRef producer connector source references) = object
      ["producer" .= producer,"connector" .= connector,"source" .= source,"externalReferences" .= references]

parseProposal :: CheckedContract -> Value -> Parser FactProposal
parseProposal state = withObject "Fact proposal" $ \fields -> do
  steps <- fields .: "steps" >>= traverse (withObject "Proposed step" $ \step -> do
    why <- step .: "rationale" >>= withObject "Rationale" (\rationale ->
      Rationale <$> rationale .: "explanation" <*> (rationale .: "evidence" >>= traverse
        (withObject "Evidence reference" $ \evidence -> EvidenceRef
          <$> evidence .: "producer" <*> evidence .: "connector" <*> evidence .: "source" <*> evidence .: "externalReferences")))
    FactProposalStep why <$> step .: "edits")
  FactProposal steps . CheckedValue (contractId state) <$> fields .: "state"

proposalChange :: DhallHandling :> es => RootContract -> CheckedContract -> FactProposal -> Eff es (Either [Diagnostic] FileTree)
proposalChange contract state proposal@(FactProposal _ (CheckedValue identity _)) = runExceptT $ do
  unless (identity == contractId state) (throwE [errorDiagnostic "proposal.state-contract" "Proposal state differs from the selected recipe's contract"])
  shape <- checked (proposalShape contract state)
  encoded <- ExceptT (encodeValue shape (proposalValue proposal))
  path <- checked (relativePath "proposal.dhall")
  entry <- checked (relativePath "Evolution.hs")
  checked (fileTree [(path,Text.encodeUtf8 encoded),(entry,Text.encodeUtf8 (Text.pack (unlines
    ["module Evolution where", "import Kyyn.Workspace.Evolution",
     "import KyynFrozenProposal (frozen)",
     "evolution :: RecipeEvolution Root RecipeState",
     "evolution = frozen"])))])

-- | Decode captured Dhall inputs before compiling their ordinary pure entry.
lowerProposal :: DhallHandling :> es => RootContract -> RootContract -> Maybe (CheckedContract, CheckedValue) -> FileTree -> Eff es (Either [Diagnostic] FileTree)
lowerProposal before after selectedState change = runExceptT $ do
  path <- checked (relativePath "proposal.dhall")
  case lookup path (files change) of
    Nothing -> pure change
    Just bytes -> do
      (state,previous) <- checked (maybe (Left "Frozen proposals require a recipe-based workspace") Right selectedState)
      unless (contractId (rootSchema before) == contractId (rootSchema after))
        (throwE [errorDiagnostic "proposal.schema-changed" "Fact proposals require the same Before and After schema and metadata"])
      shape <- checked (proposalShape before state)
      source <- checked (either (Left . show) Right (Text.decodeUtf8' bytes))
      value <- ExceptT (decodeValue shape source)
      FactProposal _ next <- checked (parseEither (parseProposal state) value)
      generated <- checked (relativePath "KyynFrozenProposal.hs")
      let json = Text.unpack (Text.decodeUtf8 (Lazy.toStrict (encode value)))
          finalStep = if next == previous then "identityEvolution"
            else "recipeEdit (Rationale \"Update recipe state\" []) (putRecipeState state)"
          moduleSource = unlines
            ["{-# LANGUAGE OverloadedStrings #-}", "module KyynFrozenProposal (frozen, proposal) where",
             "import Kyyn.Workspace.Evolution", "import Kyyn.Workspace.FactEdits (RootEdit, applyRootEdit)",
             "import qualified KyynFactEditCodec", "import qualified KyynRecipeStateCodec",
             "import Kyyn.Evolution.Internal (Evolution(..))",
             "import Kyyn.Types.Evolution (EvolutionFailure(..))",
             "import Kyyn.Types.Diagnostic (Diagnostic(..), Severity(..))",
             "import Kyyn.Runtime.Json", "import qualified Data.Text as Text", "import Kyyn.Runtime.Proposal (recipeProposalCodec)",
             "-- | Apply the captured proposal without invoking its recipe again.",
             "frozen :: RecipeEvolution Root RecipeState",
             "frozen = case proposal of",
             "  Right (RecipeProposal steps state) -> foldr ((>=>) . step) (" ++ finalStep ++ ") steps",
             "  Left message -> Evolution (\\_ -> Left (EvolutionFailure [Diagnostic Error \"proposal.decode\" (Text.pack message) Nothing]))",
             "step (ProposedStep why operations) = recipeEdit why (editFacts (mapM_ applyRootEdit operations))",
             "proposal :: Either String (RecipeProposal RootEdit RecipeState)",
             "proposal = parseValue " ++ show json ++ " >>= decodeWith (recipeProposalCodec KyynFactEditCodec.rootCodec KyynRecipeStateCodec.rootCodec)"]
      checked (fileTree ((generated,Text.encodeUtf8 (Text.pack moduleSource)) : filter ((/= path) . fst) (files change)))

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "proposal.invalid") pure
