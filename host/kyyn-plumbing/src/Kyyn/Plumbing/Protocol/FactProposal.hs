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
lowerProposal :: DhallHandling :> es => RootContract -> Maybe (CheckedContract, CheckedValue) -> FileTree -> Eff es (Either [Diagnostic] FileTree)
lowerProposal target selectedState change = runExceptT $ do
  path <- checked (relativePath "proposal.dhall")
  case lookup path (files change) of
    Nothing -> pure change
    Just bytes -> do
      (state,previous) <- checked (maybe (Left "Frozen proposals require a recipe-based workspace") Right selectedState)
      shape <- checked (proposalShape target state)
      source <- checked (either (Left . show) Right (Text.decodeUtf8' bytes))
      value <- ExceptT (decodeValue shape source)
      FactProposal _ next <- checked (parseEither (parseProposal state) value)
      generated <- checked (relativePath "KyynFrozenProposal.json")
      -- The guest compiler owns the Haskell facade; the host supplies validated
      -- proposal data and whether the selected recipe state actually changed.
      let payload = Lazy.toStrict (encode (value, next /= previous))
      checked (fileTree ((generated,payload) : filter ((/= path) . fst) (files change)))


checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "proposal.invalid") pure
