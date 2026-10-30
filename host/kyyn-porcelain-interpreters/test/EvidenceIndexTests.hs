-- Standard binary Dhall index, generated descriptors and indexed metadata.
-- No payload IO or guest compilation; store-selectivity is tested at the store.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.Text as Text
import Effectful (runPureEff)
import Kyyn.Domain.Blob (sdkBlobRefType)
import Data.Either (isLeft)
import Kyyn.Domain.Contract (checkContract, contractId)
import Kyyn.Domain.DataType (DataType(..), Constructor(..), Shape(..), ScalarKind(..))
import Kyyn.Domain.Evidence
import Kyyn.Domain.EvidenceIndex
import Kyyn.Domain.Plugin (PackageIdentity(..), ConnectorTypeName(..), pluginName)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (encodeBinaryValue)
import Kyyn.Plumbing.Protocol.DataType (dataTypeShape, dataTypeValue)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Porcelain.Protocol.EvidenceIndex
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))

main :: IO ()
main = do
  contract <- either (fail . show) pure (checkContract TextType (SchemaMetadata [] [] []))
  position <- either (fail . show) pure (checkContract IntegerType (SchemaMetadata [] [] []))
  plugin <- either (fail . show) pure (pluginName "fixture")
  let summary = FetchSummary (FetchId "first") "2026-10-08T00:00:00Z" 2 0 0 Nothing
      item = (EvidenceId "mail-雪",Evidence (EvidenceFingerprint "opaque") ["https://example.test/mail"]
        (Available (PayloadLocation (Text.replicate 64 "a") 24 [])))
      truncated = (EvidenceId "gone-payload",Evidence (EvidenceFingerprint "retained") [] Truncated)
      document = IndexDocument (PackageIdentity "source") (ConnectorTypeName "Mail") contract
        (EvidenceState summary [item,truncated]) (Just (position,CheckedValue (contractId position) (String "42"))) (Just (FetchReport contract (CheckedValue (contractId contract) (String "public report"))))
      encode d = runPureEff (runDhallHandling (encodeIndex d))
      decode b = runPureEff (runDhallHandling (decodeIndex b))
  bytes <- either (fail . show) pure (encode document)
  restored <- either (fail . show) pure (decode bytes)
  unless (restored == document) (fail "Index round trip lost descriptor, position or metadata")
  let index = capturedIndex (ConnectorInstanceRef plugin "mail") restored
  unless (indexedEvidence index (EvidenceId "mail-雪") == Just (snd item)) (fail "Indexed read lost item")
  unless (indexedEvidence index (EvidenceId "absent") == Nothing) (fail "Missing ID not absent")
  let malformed = IndexDocument (PackageIdentity "source") (ConnectorTypeName "Mail") contract
        (EvidenceState summary [item,item]) Nothing Nothing
  case encode malformed of
    Left _ -> pure ()
    Right _ -> fail "Duplicate index IDs accepted"
  case decode "not binary Dhall" of
    Left _ -> pure ()
    Right _ -> fail "Malformed index accepted"
  let reportValue = String "public report"
      report = Just (FetchReport contract (CheckedValue (contractId contract) reportValue))
      cursor = Just (position,CheckedValue (contractId position) (String "42"))
      state = EvidenceState summary [item,truncated]
      fixture = IndexDocument (PackageIdentity "source") (ConnectorTypeName "Mail") contract state
  unless (isLeft (encode (fixture cursor Nothing))) (fail "Missing report was silently accepted")
  unless (isLeft (encode (fixture Nothing report))) (fail "Report without context was silently accepted")
  unless (isLeft (encode (fixture cursor (Just (FetchReport contract (CheckedValue (contractId contract) (Bool True)))))))
    (fail "Malformed report value accepted")
  unless (isLeft (encode (fixture cursor (Just (FetchReport contract (CheckedValue (contractId position) reportValue))))))
    (fail "Mismatched report contract accepted")
  mapM_ (\shape -> do
    reportContract <- either (fail . show) pure (checkContract shape (SchemaMetadata [] [] []))
    unless (isLeft (validateReportContract reportContract)) (fail "Nested report BlobRef accepted"))
    [sdkBlobRefType,ListType sdkBlobRefType,OptionalType sdkBlobRefType,
      Algebraic "Fixture.Report" [] [Constructor "Fixture.Report" [(Just "file",sdkBlobRefType)]]]
  -- Produce valid binary Dhall with deliberately inconsistent descriptor/value pairs.
  -- This bypasses encodeIndex's guards and exercises the untrusted stored-input path.
  let scalar = Scalar TextScalar
      natural = Scalar IntegerScalar
      optionalValue :: Maybe Value -> Value
      optionalValue Nothing = object ["tag" .= ("None" :: String)]
      optionalValue (Just v) = object ["tag" .= ("Some" :: String), "value" .= v]
      header legacy = Record ([("producer",scalar),("connector",scalar),("payloadType",dataTypeShape),
        ("positionType",Optional dataTypeShape)] ++ [("reportType",Optional dataTypeShape) | not legacy])
      latest = Record [("identity",scalar),("fetchedAt",scalar),("added",natural),("updated",natural),("removed",natural),("options",Optional scalar)]
      location = Record [("sha256",scalar),("size",natural),("blobs",List (Record
        [("sha256",scalar),("size",natural),("mediaType",scalar),("name",Optional scalar)]))]
      entry = Record [("id",scalar),("evidence",Record [("fingerprint",scalar),("externalReferences",List scalar),
        ("payload",Union [("Available",Just location),("Truncated",Nothing)])])]
      raw = rawWith False
      rawWith legacy reportDescriptor reportShape reportBody = runPureEff $ runDhallHandling $ encodeBinaryValue
        (Record [("header",header legacy),("body",Record [("latest",latest),("values",List entry),
          ("position",Optional natural),("report",Optional reportShape)])])
        (object ["header" .= object (["producer" .= ("source" :: String),"connector" .= ("Mail" :: String),
          "payloadType" .= dataTypeValue TextType,"positionType" .= optionalValue (Just (dataTypeValue IntegerType))] ++
          ["reportType" .= optionalValue reportDescriptor | not legacy]),
          "body" .= object ["latest" .= object ["identity" .= ("first" :: String),"fetchedAt" .= ("now" :: String),
            "added" .= ("0" :: String),"updated" .= ("0" :: String),"removed" .= ("0" :: String),"options" .= optionalValue Nothing],
            "values" .= ([] :: [Value]),"position" .= optionalValue (Just (String "42")),"report" .= optionalValue reportBody]])
  validRaw <- either (fail . show) pure (raw (Just (dataTypeValue TextType)) scalar (Just (String "report")))
  _ <- either (fail . show) pure (decode validRaw)
  mapM_ (\encoded -> do
    invalidBytes <- either (fail . show) pure encoded
    unless (isLeft (decode invalidBytes)) (fail "Malformed stored report descriptor/value accepted"))
    [rawWith True (Just (dataTypeValue TextType)) scalar (Just (String "report")),
     raw (Just (dataTypeValue TextType)) scalar Nothing,
     raw Nothing (Record []) (Just (object [])),
     raw (Just (dataTypeValue TextType)) (Scalar BoolScalar) (Just (Bool True))]
  putStrLn "Evidence index: descriptor/position/metadata round trip and identity validation passed."
