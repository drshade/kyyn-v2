module Kyyn.Plumbing.Protocol.Candidate (encodeCandidateMetadata, decodeCandidateMetadata) where

import Data.Aeson (Value, toJSON, encode, eitherDecodeStrict')
import Data.Aeson.Types (Parser, parseEither, parseJSON)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import Kyyn.Domain.Contract
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution (EvolutionId, evolutionId, evolutionIdName)
import Kyyn.Domain.EvolutionReport
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Fact (FactId(..))

encodeCandidateMetadata :: EvolutionId -> RootContract -> RootContract -> EvolutionReport -> ByteString
encodeCandidateMetadata identity before after (EvolutionReport steps) = Lazy.toStrict $ encode
  (1 :: Int, evolutionIdName identity, describeRootContract before, describeRootContract after, map step steps)
  where
    step (StepReport (Rationale explanation evidence) changes) = toJSON
      (explanation, [(p,c,s,rs) | EvidenceRef p c s rs <- evidence], map change changes)
    change (FactChange collection (FactId identity') old new) = toJSON
      (collection, identity', fmap fact old, fmap fact new)
    fact (RecordedFact schema value) = (describeRootContract schema,value)

decodeCandidateMetadata :: ByteString
  -> Either String (Either [Diagnostic] (EvolutionId, RootContract, RootContract, EvolutionReport))
decodeCandidateMetadata bytes = eitherDecodeStrict' bytes >>= parseEither metadata
  where
    metadata value = do
      (version, name, before, after, steps) <- parseJSON value
      identity <- either fail pure (evolutionId name)
      if version /= (1 :: Int)
        then pure (Left [errorDiagnostic "candidate.stale" "Saved result format is no longer supported; apply the evolution again"])
        else do
          source <- contract before
          target <- contract after
          report <- traverse step steps
          pure $ (\b a rs -> (identity,b,a,EvolutionReport rs)) <$> source <*> target <*> sequence report
    step value = do
      (explanation, evidence, changes) <- parseJSON value
      restored <- traverse change changes
      pure (StepReport (Rationale explanation [EvidenceRef p c s rs | (p,c,s,rs) <- evidence]) <$> sequence restored)
    change value = do
      (collection, identity, before, after) <- parseJSON value
      old <- traverse fact before
      new <- traverse fact after
      pure (FactChange collection (FactId identity) <$> sequence old <*> sequence new)
    fact value = do
      (description, recorded) <- parseJSON value
      restored <- contract description
      pure (flip RecordedFact recorded <$> restored)

contract :: Value -> Parser (Either [Diagnostic] RootContract)
contract = either fail pure . restoreRootContract
