{-# LANGUAGE DerivingStrategies, DeriveAnyClass, DeriveGeneric, TypeApplications, OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
module Main (main) where

import qualified Agentic.Contract as A
import qualified Agentic.Codec as C
import qualified Agentic.Schema as S
import Agentic.Value (Value(..))
import Agentic.Questions (Probability, fromBasisPoints)
import Control.Monad (unless, forM_)
import qualified Data.Aeson as Json
import qualified Kyyn.Types.Contract as D
import qualified Kyyn.Domain.Contract as Host
import qualified Kyyn.Domain.DataType as Host
import Kyyn.Types.SchemaMetadata
import Data.Either (isLeft)
import Data.Fixed (Fixed(..), E2)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, fromGregorian, UTCTime(..), secondsToDiffTime)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Kyyn.Contract
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.Blob (BlobRef(..))

data Item = Item { key :: FactId, amount :: Fixed E2, confidence :: Probability }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Contract)
data Root = Root { items :: [Fact Item] } deriving stock (Eq, Show, Generic)
  deriving anyclass (Contract)
data EmptyRoot = EmptyRoot deriving stock (Eq, Show, Generic)
  deriving anyclass (Contract)
data Choice = Missing | Amount (Fixed E2) | NamedAmount { title :: Text, units :: Natural }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Contract)
newtype Decimal = Decimal Integer deriving stock (Eq, Show, Generic)
  deriving anyclass (Contract)
newtype Label = Label { label :: Text } deriving stock (Eq, Show, Generic)
  deriving anyclass (Contract)
data Recursive = End | Next Recursive deriving stock (Generic)
  deriving anyclass (Contract)
data Box a = Box { value :: a } deriving stock (Generic)
  deriving anyclass (Contract)
newtype Unknown = Unknown Text deriving (Eq, Show)
instance Contract Unknown where
  contract = A.scalar (A.ScalarInfo "example.Unknown" []) (Just model)
    where model = C.primitive (S.SString Nothing) (\(Unknown t) -> String t) $ \v -> case v of
            String t -> Right (Unknown t)
            _ -> Left "expected text"

expect :: String -> Bool -> IO ()
expect name ok = unless ok (fail name)

compiled :: Contract a => IO (Codec a)
compiled = either (fail . show) pure (compileWire contract)

roundTrip :: (Contract a, Eq a, Show a) => String -> a -> IO ()
roundTrip name value = do
  codec <- compiled
  expect name (codec.decode (codec.encode value) == Right value)

main :: IO ()
main = do
  let rootMetadata = SchemaMetadata [] [] [CollectionDecl "items" "items" []]
  rootCompiled <- either (fail . show) pure (compileContract (contract @Root))
  hostRoot <- either (fail . show) pure (Host.checkContract rootCompiled.description rootMetadata >>= Host.checkRootLayout)
  let hostContract = Host.rootSchema hostRoot
  expect "host and guest contract identity" (Host.contractId hostContract == D.contractIdentity rootCompiled.description rootMetadata)
  expect "host retains complete descriptor" (Host.descriptionOf hostContract == rootCompiled.description)
  expect "host discovers fact payload" (length (Host.collectionContracts hostContract) == 1)
  expect "host exact scalar projection" $ case Host.contractShape hostContract of
    Host.Record [("items", Host.List (Host.Record [("id",_), ("value",Host.Record fields)]))] ->
      lookup "amount" fields == Just (Host.Scalar (Host.ExactScalar (D.DecimalScalar 100)))
    _ -> False
  expect "host rejects undeclared collection" (isLeft (Host.checkContract rootCompiled.description (SchemaMetadata [] [] []) >>= Host.checkRootLayout))
  let item = Item (FactId "sample-1") (MkFixed 1234) (fromBasisPoints 8500)
  compiledItem <- either (fail . show) pure (compileContract (contract @Item))
  let description = compiledItem.description
      metadata = SchemaMetadata [] [] []
      identity = D.contractIdentity description metadata
  expect "stable identity golden" (D.fingerprint (D.contractIdentity D.UnitDescription metadata) == "b7d9436b9428811f8400304bd59d0a3a7a04968a23ba3876cc414c503e759783")
  expect "description transport round trip" (Json.eitherDecode (Json.encode description) == Right description)
  expect "identity transport round trip" (D.parseFingerprint (D.fingerprint identity) == Right identity)
  expect "metadata participates in identity" (identity /= D.contractIdentity description
    (SchemaMetadata [RoleDecl "title" "item name" Title] [] []))
  expect "description annotations participate in identity" (identity /= D.contractIdentity
    (D.DocumentedDescription "changed" description) metadata)
  expect "host recomputation from decoded description" $ case Json.eitherDecode (Json.encode description) of
    Left _ -> False
    Right decoded -> D.contractIdentity decoded metadata == identity
  expect "invalid decimal descriptor" (isLeft (D.validateDescription (D.ScalarDescription
    (D.TypeIdentity "pkg" "Module" "Decimal" []) (D.DecimalScalar 0) "decimal" [])))
  expect "descriptor rejects unknown fields" (isLeft
    (Json.eitherDecode "{\"types\":[],\"nodes\":[{\"tag\":\"Unit\",\"extra\":true}]}" :: Either String D.Description))
  expect "metadata rejects unknown fields" (isLeft
    (Json.eitherDecode "{\"roles\":[],\"fields\":[],\"collections\":[],\"extra\":true}" :: Either String SchemaMetadata))
  expect "invalid fingerprint" (isLeft (D.parseFingerprint "not-a-digest"))
  stored <- compiled @Item
  expect "record wire profile" $ stored.encode item == Object
    [("key",String "sample-1"),("amount",String "12.34"),("confidence",String "8500")]
  model <- either (fail . show) pure (A.compileModel (contract @Item))
  expect "independent model probability" $ model.encode item == Object
    [("key",String "sample-1"),("amount",String "12.34"),("confidence",Number 0.85)]
  factId <- compiled @FactId
  expect "empty fact ID" (isLeft (factId.decode (String "")))
  roundTrip "fact envelopes" (Root [Fact (FactId "fact-1") item])
  forM_ [0, -1234, 123456789012345678901234567890123456789] $ \n ->
    roundTrip "exact fixed decimals" (MkFixed n :: Fixed E2)
  decimal <- compiled @(Fixed E2)
  forM_ ["NaN","1e2","01.00","12.345","-0.0"] $ \t ->
    expect ("malformed decimal " ++ show t) (isLeft (decimal.decode (String t)))
  probability <- compiled @Probability
  forM_ ["-1","10001","8500.0","08500"] $ \t ->
    expect "probability validates before clamping" (isLeft (probability.decode (String t)))
  expect "storage refuses model numbers" (isLeft (probability.decode (Number 0.85)))
  natural <- compiled @Natural
  expect "negative natural" (isLeft (natural.decode (String "-1")))
  integer <- compiled @Integer
  forM_ ["+1","01","1.0","-0"," 1"] $ \t ->
    expect "canonical integers" (isLeft (integer.decode (String t)))
  bounded <- compiled @Int
  expect "bounded Int" (isLeft (bounded.decode (String (T.pack (show (toInteger (maxBound :: Int) + 1))))))
  options <- compiled @(Maybe (Maybe Integer))
  expect "nested optional distinction" $ map options.encode [Nothing,Just Nothing,Just (Just 7)] ==
    [Object [("tag",String "None")],
     Object [("tag",String "Some"),("value",Object [("tag",String "None")])],
     Object [("tag",String "Some"),("value",Object [("tag",String "Some"),("value",String "7")])]]
  forM_ [Nothing,Just Nothing,Just (Just 7)] (roundTrip "nested optional round trip" :: Maybe (Maybe Integer) -> IO ())
  expect "optional rejects extra fields" (isLeft (options.decode (Object [("tag",String "None"),("value",String "7")])))
  choice <- compiled @Choice
  expect "nullary union" (choice.encode Missing == Object [("tag",String "Missing")])
  expect "positional payload" (choice.encode (Amount (MkFixed 1234)) == Object [("tag",String "Amount"),("value",String "12.34")])
  expect "record payload" (choice.encode (NamedAmount "x" 2) == Object
    [("tag",String "NamedAmount"),("value",Object [("title",String "x"),("units",String "2")])])
  forM_ [Missing,Amount (MkFixed (-1234)),NamedAmount "x" 2] (roundTrip "sum round trip")
  wrapper <- compiled @Decimal
  expect "no scalar guessing from name" (wrapper.encode (Decimal 42) == Object [("tag",String "Decimal"),("value",String "42")])
  label <- compiled @Label
  expect "record wrapper" (label.encode (Label "x") == Object [("label",String "x")])
  empty <- compiled @EmptyRoot
  unit <- compiled @()
  expect "empty root and unit" (empty.encode EmptyRoot == Object [] && unit.encode () == Object [])
  expect "nominal empty identity" (A.outline (contract @EmptyRoot) /= A.outline (contract @()))
  expect "applied type identity" (A.outline (contract @(Box (Fixed E2))) /= A.outline (contract @(Box Probability)))
  expect "reject unsupported scalar in empty container" (isLeft (compileWire (contract @[Unknown])))
  expect "reject model Double storage" (isLeft (compileWire (contract @Double)))
  expect "reject recursive contract before outline" (isLeft (compileContract (contract @Recursive)))
  expect "reject multi-positional tuples" (isLeft (compileWire (contract @(Integer,Integer))))
  checked <- either (fail . show) pure (compileWire (A.checked "positive" (> (0 :: Integer)) contract))
  expect "checked contract validation retained" (isLeft (checked.decode (String "-1")))
  expect "missing fields" (isLeft (stored.decode (Object [])))
  expect "unknown fields" (isLeft (stored.decode (Object [("extra",String "x")])) )
  let day = fromGregorian 2026 11 6
  roundTrip "date" (day :: Day)
  roundTrip "instant" (UTCTime day (secondsToDiffTime 12345))
  let blob = BlobRef (T.replicate 64 "a") 12 "text/plain" (Just "notes.txt")
  roundTrip "blob identity and fields" blob
  blobWire <- compiled @BlobRef
  expect "blob rejects unknown fields" $ case blobWire.encode blob of
    Object fields -> isLeft (blobWire.decode (Object (("extra",String "x"):fields)))
    _ -> False
  expect "blob rejects duplicate fields" $ case blobWire.encode blob of
    Object fields -> isLeft (blobWire.decode (Object (("size",String "12"):fields)))
    _ -> False
  putStrLn "Contract interpreter: exact scalars, structural codecs, discovery and failure checks passed."
