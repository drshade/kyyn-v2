module Kyyn.Plumbing.Protocol.EvolutionRecord (encodeEvolutionRecord, decodeEvolutionRecord) where

import Data.ByteString (ByteString)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionId)
import Kyyn.Domain.EvolutionReport (EvolutionReport)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Protocol.EvolutionRecord.Document (recordDocument, recordShape, headerShape, decodeHeader, decodeRecord)

encodeEvolutionRecord :: DhallHandling :> es => EvolutionId -> RootContract -> RootContract -> EvolutionReport
  -> Eff es (Either [Diagnostic] ByteString)
encodeEvolutionRecord identity before after report = case recordDocument identity before after report of
  Left diagnostics -> pure (Left diagnostics)
  Right (shape,value) -> fmap (fmap Text.encodeUtf8) (encodeValue shape value)

decodeEvolutionRecord :: DhallHandling :> es => ByteString
  -> Eff es (Either String (Either [Diagnostic] (EvolutionId, RootContract, RootContract, EvolutionReport)))
decodeEvolutionRecord bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (Left (show problem))
  Right contents -> decodeContents contents
  where
    decodeContents contents = do
      decoded <- decodeValue headerShape ("(" <> contents <> "\n).{identity, before, after, recipeContracts}")
      case decoded of
        Left diagnostics -> pure (Left (show diagnostics))
        Right value -> case decodeHeader value of
          Right (Right (identity,before,after,states)) -> do
            checked <- decodeValue (recordShape states before after) contents
            pure $ case checked of
              Left diagnostics -> Left (show diagnostics)
              Right document -> (\report -> Right (identity,before,after,report)) <$> decodeRecord states before after document
          Right (Left diagnostics) -> pure (Right (Left diagnostics))
          Left message -> pure (Left message)
