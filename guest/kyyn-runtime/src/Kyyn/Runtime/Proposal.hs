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
      [("explanation",encodeWith stringCodec explanation),("evidence",encodeWith (listCodec evidenceCodec) evidence)]
    decode value = do
      values <- fields ["explanation","evidence"] value
      Rationale <$> field "explanation" stringCodec values <*> field "evidence" (listCodec evidenceCodec) values
    evidenceCodec = Codec encodeEvidence decodeEvidence
    encodeEvidence (EvidenceRef producer connector source references) = record
      [("producer",encodeWith stringCodec producer),("connector",encodeWith stringCodec connector),
       ("source",encodeWith stringCodec source),("references",encodeWith (listCodec stringCodec) references)]
    decodeEvidence value = do
      values <- fields ["producer","connector","source","references"] value
      EvidenceRef <$> field "producer" stringCodec values <*> field "connector" stringCodec values
        <*> field "source" stringCodec values <*> field "references" (listCodec stringCodec) values

curationCodec :: Codec Curation
curationCodec = Codec encode decode
  where
    encode (Curation (RecipeId recipe) handled) = record
      [("recipe",encodeWith stringCodec recipe),("handled",encodeWith (listCodec acknowledgementCodec) handled)]
    decode value = do
      values <- fields ["recipe","handled"] value
      Curation <$> (RecipeId <$> field "recipe" stringCodec values)
        <*> field "handled" (listCodec acknowledgementCodec) values
    acknowledgementCodec = Codec encodeAcknowledgement decodeAcknowledgement
    encodeAcknowledgement (EntireBatch scope) = tagged "EntireBatch" (Just (encodeWith scopeCodec scope))
    encodeAcknowledgement (IndividualRecords scope ids) = tagged "IndividualRecords" (Just (record
      [("scope",encodeWith scopeCodec scope),("ids",encodeWith (listCodec stringCodec) [name | EvidenceId name <- ids])]))
    decodeAcknowledgement value = do
      selected <- variant value
      case selected of
        ("EntireBatch",Just scope) -> EntireBatch <$> decodeWith scopeCodec scope
        ("IndividualRecords",Just payload) -> do
          values <- fields ["scope","ids"] payload
          IndividualRecords <$> field "scope" scopeCodec values
            <*> (map EvidenceId <$> field "ids" (listCodec stringCodec) values)
        _ -> Left "Unknown evidence acknowledgement"
    scopeCodec = Codec encodeScope decodeScope
    encodeScope (EvidenceScope plugin instanceName fetch) = record
      [("plugin",encodeWith stringCodec plugin),("instance",encodeWith stringCodec instanceName),("fetch",encodeWith stringCodec fetch)]
    decodeScope value = do
      values <- fields ["plugin","instance","fetch"] value
      EvidenceScope <$> field "plugin" stringCodec values <*> field "instance" stringCodec values <*> field "fetch" stringCodec values
