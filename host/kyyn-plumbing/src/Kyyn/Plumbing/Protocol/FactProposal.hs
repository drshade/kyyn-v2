module Kyyn.Plumbing.Protocol.FactProposal
  ( proposalShape, proposalValue, parseProposal, proposalChange, lowerProposal ) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value, object, (.=), (.:), withObject, encode)
import Data.Aeson.Types (Parser)
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
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Protocol.Curation (curationDeclarationShape, curationDeclarationValue, parseCuration)
import Kyyn.Plumbing.Protocol.FactEdits (factEditType)

proposalShape :: RootContract -> Either String Shape
proposalShape contract = do
  unless (not (null (collectionContracts (rootSchema contract)))) (Left "Fact proposals require a domain fact collection")
  edits <- shapeOf (ListType (factEditType contract))
  pure (Record [("steps",List (Record [("rationale",rationale),("edits",edits)])),("curation",curationDeclarationShape)])
  where
    text = Scalar TextScalar
    rationale = Record [("explanation",text),("evidence",List (Record
      [("producer",text),("connector",text),("source",text),("references",List text)]))]

proposalValue :: FactProposal -> Value
proposalValue (FactProposal steps curation) = object
  ["steps" .= map step steps,"curation" .= curationDeclarationValue curation]
  where
    step (FactProposalStep (Rationale explanation evidence) edits) = object
      ["rationale" .= object ["explanation" .= explanation,"evidence" .= map citation evidence],"edits" .= edits]
    citation (EvidenceRef producer connector source references) = object
      ["producer" .= producer,"connector" .= connector,"source" .= source,"references" .= references]

parseProposal :: Value -> Parser FactProposal
parseProposal = withObject "Fact proposal" $ \fields -> do
  steps <- fields .: "steps" >>= traverse (withObject "Proposed step" $ \step -> do
    why <- step .: "rationale" >>= withObject "Rationale" (\rationale ->
      Rationale <$> rationale .: "explanation" <*> (rationale .: "evidence" >>= traverse
        (withObject "Evidence reference" $ \evidence -> EvidenceRef
          <$> evidence .: "producer" <*> evidence .: "connector" <*> evidence .: "source" <*> evidence .: "references")))
    FactProposalStep why <$> step .: "edits")
  value <- fields .: "curation" :: Parser Value
  declaration <- parseCuration (object ["tag" .= ("Some" :: String),"value" .= value])
  maybe (fail "Proposal must declare curation") (pure . FactProposal steps) declaration

proposalChange :: DhallHandling :> es => RootContract -> FactProposal -> Eff es (Either [Diagnostic] FileTree)
proposalChange contract proposal = runExceptT $ do
  shape <- checked (proposalShape contract)
  encoded <- ExceptT (encodeValue shape (proposalValue proposal))
  path <- checked (relativePath "proposal.dhall")
  entry <- checked (relativePath "Evolution.hs")
  checked (fileTree [(path,Text.encodeUtf8 encoded),(entry,Text.encodeUtf8 (Text.pack (unlines
    ["module Evolution where", "import Kyyn.Workspace.Evolution", "import Kyyn.Workspace.FactEdits",
     "import qualified " ++ definingModule (case rootType (rootSchema contract) of Algebraic name _ _ -> name; _ -> error "Checked root is not algebraic"),
     "import qualified KyynFrozenProposal", "import Kyyn.Types.Diagnostic",
     "evolution :: Evolution (KnowledgeBase " ++ root ++ ") (KnowledgeBase " ++ root ++ ")",
     "evolution = case KyynFrozenProposal.proposal of",
     "  Right value -> proposalEvolution value",
     "  Left message -> edit (Rationale \"Decode proposal\" []) (refuse [Diagnostic Error \"proposal.decode\" message Nothing])"])))])
  where root = haskellType (rootType (rootSchema contract))

-- | Decode captured Dhall inputs before compiling their ordinary pure entry.
lowerProposal :: DhallHandling :> es => RootContract -> RootContract -> FileTree -> Eff es (Either [Diagnostic] FileTree)
lowerProposal before after change = runExceptT $ do
  path <- checked (relativePath "proposal.dhall")
  case lookup path (files change) of
    Nothing -> pure change
    Just bytes -> do
      unless (contractId (rootSchema before) == contractId (rootSchema after))
        (throwE [errorDiagnostic "proposal.schema-changed" "Fact proposals require the same Before and After schema and metadata"])
      shape <- checked (proposalShape before)
      source <- checked (either (Left . show) Right (Text.decodeUtf8' bytes))
      value <- ExceptT (decodeValue shape source)
      generated <- checked (relativePath "KyynFrozenProposal.hs")
      let json = Text.unpack (Text.decodeUtf8 (Lazy.toStrict (encode value)))
          moduleSource = unlines
            ["module KyynFrozenProposal (proposal) where", "import Kyyn.Evolution.Proposal (ProposedCuration)",
             "import Kyyn.Workspace.FactEdits (RootEdit)", "import KyynFactEditCodec (rootCodec)",
             "import Kyyn.Runtime.Json", "import Kyyn.Runtime.Proposal (proposalCodec)",
             "proposal :: Either String (ProposedCuration RootEdit)",
             "proposal = parseValue " ++ show json ++ " >>= decodeWith (proposalCodec rootCodec)"]
      checked (fileTree ((generated,Text.encodeUtf8 (Text.pack moduleSource)) : filter ((/= path) . fst) (files change)))

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "proposal.invalid") pure
