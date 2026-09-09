module Kyyn.Plumbing.Protocol.EvolutionRecord (encodeEvolutionRecord, decodeEvolutionRecord) where

import Data.ByteString (ByteString)
import Data.Aeson (Value(String))
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.DataType (Shape(Scalar), ScalarKind(IntegerScalar))
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
  Right contents -> do
    version <- decodeValue (Scalar IntegerScalar) ("(" <> contents <> "\n).version")
    case version of
      Left diagnostics -> pure (Left (show diagnostics))
      Right (String "1") -> decodeContents contents
      Right _ -> pure (Right (Left [errorDiagnostic "evolution.record-format"
        "Stored evolution record format is not supported by this kernel"]))
  where
    decodeContents contents = do
      decoded <- decodeValue headerShape ("(" <> contents <> "\n).{version, identity, before, after}")
      case decoded of
        Left diagnostics -> pure (Left (show diagnostics))
        Right value -> case decodeHeader value of
          Right (Right (identity,before,after)) -> do
            checked <- decodeValue (recordShape before after) contents
            pure $ case checked of
              Left diagnostics -> Left (show diagnostics)
              Right document -> (\report -> Right (identity,before,after,report)) <$> decodeRecord before after document
          Right (Left diagnostics) -> pure (Right (Left diagnostics))
          Left message -> pure (Left message)
