module Kyyn.Runtime.Proposal (proposalCodec) where

import Kyyn.Evolution.Proposal (ProposedCuration(..), ProposedStep(..))
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..), EvidenceId(..))
import Kyyn.Types.Curation
import Kyyn.Runtime.Json

proposalCodec :: Codec edits -> Codec (ProposedCuration edits)
proposalCodec edits = Codec encode decode
  where
    encode (ProposedCuration steps curation) = record
      [("steps",encodeWith (listCodec stepCodec) steps),("curation",encodeWith curationCodec curation)]
    decode value = do
      values <- fields ["steps","curation"] value
      ProposedCuration <$> field "steps" (listCodec stepCodec) values <*> field "curation" curationCodec values
    stepCodec = Codec encodeStep decodeStep
    encodeStep (ProposedStep why operations) = record
      [("rationale",encodeWith rationaleCodec why),("edits",encodeWith (listCodec edits) operations)]
    decodeStep value = do
      values <- fields ["rationale","edits"] value
      ProposedStep <$> field "rationale" rationaleCodec values <*> field "edits" (listCodec edits) values

rationaleCodec :: Codec Rationale
rationaleCodec = Codec encode decode
  where
    encode (Rationale explanation evidence) = record
      [("explanation",encodeWith textCodec explanation),("evidence",encodeWith (listCodec evidenceCodec) evidence)]
    decode value = do
      values <- fields ["explanation","evidence"] value
      Rationale <$> field "explanation" textCodec values <*> field "evidence" (listCodec evidenceCodec) values
    evidenceCodec = Codec encodeEvidence decodeEvidence
    encodeEvidence (EvidenceRef producer connector source references) = record
      [("producer",encodeWith textCodec producer),("connector",encodeWith textCodec connector),
       ("source",encodeWith textCodec source),("references",encodeWith (listCodec textCodec) references)]
    decodeEvidence value = do
      values <- fields ["producer","connector","source","references"] value
      EvidenceRef <$> field "producer" textCodec values <*> field "connector" textCodec values
        <*> field "source" textCodec values <*> field "references" (listCodec textCodec) values

curationCodec :: Codec Curation
curationCodec = Codec encode decode
  where
    encode (Curation (RecipeId recipe) handled) = record
      [("recipe",encodeWith textCodec recipe),("handled",encodeWith (listCodec acknowledgementCodec) handled)]
    decode value = do
      values <- fields ["recipe","handled"] value
      Curation <$> (RecipeId <$> field "recipe" textCodec values)
        <*> field "handled" (listCodec acknowledgementCodec) values
    acknowledgementCodec = Codec encodeAcknowledgement decodeAcknowledgement
    encodeAcknowledgement (EntireBatch scope) = tagged "EntireBatch" (Just (encodeWith scopeCodec scope))
    encodeAcknowledgement (IndividualRecords scope ids) = tagged "IndividualRecords" (Just (record
      [("scope",encodeWith scopeCodec scope),("ids",encodeWith (listCodec textCodec) [name | EvidenceId name <- ids])]))
    decodeAcknowledgement value = do
      selected <- variant value
      case selected of
        ("EntireBatch",Just scope) -> EntireBatch <$> decodeWith scopeCodec scope
        ("IndividualRecords",Just payload) -> do
          values <- fields ["scope","ids"] payload
          IndividualRecords <$> field "scope" scopeCodec values
            <*> (map EvidenceId <$> field "ids" (listCodec textCodec) values)
        _ -> Left "Unknown evidence acknowledgement"
    scopeCodec = Codec encodeScope decodeScope
    encodeScope (EvidenceScope plugin instanceName fetch) = record
      [("plugin",encodeWith textCodec plugin),("instance",encodeWith textCodec instanceName),("fetch",encodeWith textCodec fetch)]
    decodeScope value = do
      values <- fields ["plugin","instance","fetch"] value
      EvidenceScope <$> field "plugin" textCodec values <*> field "instance" textCodec values <*> field "fetch" textCodec values
