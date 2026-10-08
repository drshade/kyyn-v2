module Kyyn.Runtime.Proposal (recipeProposalCodec) where

import Kyyn.Evolution.Proposal (ProposedStep(..), RecipeProposal(..))
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Runtime.Json

recipeProposalCodec :: Codec edits -> Codec state -> Codec (RecipeProposal edits state)
recipeProposalCodec edits state = Codec encode decode
  where
    encode (RecipeProposal steps next) = record
      [("steps",encodeWith (listCodec (proposedStepCodec edits)) steps),("state",encodeWith state next)]
    decode value = do
      values <- fields ["steps","state"] value
      RecipeProposal <$> field "steps" (listCodec (proposedStepCodec edits)) values <*> field "state" state values

proposedStepCodec :: Codec edits -> Codec (ProposedStep edits)
proposedStepCodec edits = Codec encode decode
  where
    encode (ProposedStep why operations) = record
      [("rationale",encodeWith rationaleCodec why),("edits",encodeWith (listCodec edits) operations)]
    decode value = do
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
       ("source",encodeWith textCodec source),("externalReferences",encodeWith (listCodec textCodec) references)]
    decodeEvidence value = do
      values <- fields ["producer","connector","source","externalReferences"] value
      EvidenceRef <$> field "producer" textCodec values <*> field "connector" textCodec values
        <*> field "source" textCodec values <*> field "externalReferences" (listCodec textCodec) values
