{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling) where

import Data.Bifunctor (first)
import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=), toJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as Keys
import Data.Foldable (toList)
import Data.List (sort)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Void (Void)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import qualified Dhall.Binary as Binary
import qualified Dhall.Core as D
import qualified Dhall.Map as Map
import qualified Dhall.Parser as Parser
import qualified Dhall.Pretty as Pretty
import Dhall.Src (Src)
import qualified Dhall.TypeCheck as TypeCheck
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret)
import Prettyprinter (layoutPretty, defaultLayoutOptions)
import Prettyprinter.Render.Text (renderStrict)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling(..))

runDhallHandling :: Eff (DhallHandling : es) a -> Eff es a
runDhallHandling = interpret $ \_ -> \case
  InferValue contents -> pure $ do
    parsed <- first (pure . errorDiagnostic "dhall.parse" . show) (Parser.exprFromText "value" contents)
    expression <- traverse (const (Left [errorDiagnostic "dhall.import" "Values must be self-contained; imports are not supported"])) parsed
    inferred <- first (pure . errorDiagnostic "dhall.type" . show) (TypeCheck.typeOf expression)
    shape <- first (pure . errorDiagnostic "dhall.shape") (inferredShape (D.normalize inferred))
    value <- first (pure . errorDiagnostic "dhall.value") (toWire shape (D.normalize expression))
    pure (shape,value)
  DecodeValue contract contents -> pure (decodeValueSource contract contents)
  EncodeValue contract value -> pure (encodeValueSource contract value)
  DecodeBinaryValue contract contents -> pure $ do
    expression <- binaryExpression contents
    checkedValue contract expression
  DecodeBinaryEnvelope headerShape bodyShape contents -> pure $ do
    expression <- binaryExpression contents
    inferred <- first (pure . errorDiagnostic "dhall.type" . show) (TypeCheck.typeOf expression)
    let normalized = D.normalize expression
    headerExpression <- case normalized of
      D.RecordLit fields -> maybe (Left [errorDiagnostic "dhall.type" "Binary envelope is missing its header"])
        (Right . D.recordFieldValue) (Map.lookup "header" fields)
      _ -> Left [errorDiagnostic "dhall.type" "Binary envelope must be a record"]
    header <- checkedValue headerShape headerExpression
    body <- bodyShape header
    let expected = Record [("header",headerShape),("body",body)]
    unless (D.judgmentallyEqual inferred (project expected))
      (Left [errorDiagnostic "dhall.type" "Binary envelope does not match its declared contract"])
    first (pure . errorDiagnostic "dhall.internal-conversion") (toWire expected normalized)
  EncodeBinaryValue contract value -> pure $ do
    expression <- checkedExpression contract value
    pure (Lazy.toStrict (Binary.encodeExpression (D.denote expression)))
  RenderType contract -> pure (renderStrict (layoutPretty defaultLayoutOptions (Pretty.prettyExpr (project contract))) <> "\n")

binaryExpression :: ByteString -> Either [Diagnostic] (D.Expr Src Void)
binaryExpression contents = D.denote <$> first (pure . errorDiagnostic "dhall.binary" . show)
  (Binary.decodeExpression (Lazy.fromStrict contents) :: Either Binary.DecodingFailure (D.Expr Void Void))

inferredShape :: D.Expr Src Void -> Either String Shape
inferredShape D.Text = Right (Scalar TextScalar)
inferredShape D.Integer = Right (Scalar IntegerScalar)
inferredShape D.Bool = Right (Scalar BoolScalar)
inferredShape D.Natural = Right (Scalar ProbabilityScalar)
inferredShape (D.App D.List element) = List <$> inferredShape element
inferredShape (D.App D.Optional element) = Optional <$> inferredShape element
inferredShape (D.Record fields) = Record <$> traverse
  (\(name,field) -> (Text.unpack name,) <$> inferredShape (D.recordFieldValue field)) (Map.toList fields)
inferredShape (D.Union alternatives) = Union <$> traverse
  (\(name,field) -> (Text.unpack name,) <$> traverse inferredShape field) (Map.toList alternatives)
inferredShape _ = Left "The inferred Dhall type is outside Kyyn's data vocabulary"

encodeValueSource :: Shape -> Value -> Either [Diagnostic] Text
encodeValueSource contract value = do
  expression <- checkedExpression contract value
  pure (renderStrict (layoutPretty defaultLayoutOptions (Pretty.prettyExpr expression)) <> "\n")

checkedExpression :: Shape -> Value -> Either [Diagnostic] (D.Expr Src Void)
checkedExpression contract value = do
  expression <- first (pure . errorDiagnostic "dhall.wire-value") (fromWire contract value)
  _ <- first (pure . errorDiagnostic "dhall.internal-encoding" . show)
    (TypeCheck.typeOf (D.Annot expression (project contract)))
  pure expression

fromWire :: Shape -> Value -> Either String (D.Expr Src Void)
fromWire (Scalar TextScalar) (String text) = Right (D.TextLit (D.Chunks [] text))
fromWire (Reference _) value = fromWire (Scalar TextScalar) value
fromWire (Scalar IntegerScalar) (String text) = case reads (Text.unpack text) of
  [(n, "")] | Text.pack (show (n :: Integer)) == text -> Right (D.IntegerLit n)
  _ -> Left "Expected canonical integer string"
fromWire (Scalar BoolScalar) (Bool b) = Right (D.BoolLit b)
fromWire (Scalar ProbabilityScalar) (String text) = case reads (Text.unpack text) of
  [(n, "")] | n >= (0 :: Integer), n <= 10000, Text.pack (show n) == text -> Right (D.NaturalLit (fromInteger n))
  _ -> Left "Expected probability basis points in 0..10000"
fromWire (List s) (Array values) = do
  items <- traverse (fromWire s) (toList values)
  pure (D.ListLit (if null items then Just (D.App D.List (project s)) else Nothing) (Seq.fromList items))
fromWire (Record fields) value = do
  values <- exactFields (map (Text.pack . fst) fields) value
  D.RecordLit . Map.fromList <$> traverse (field values) fields
  where
    field values (name,s) = do
      item <- requireField (Text.pack name) values >>= fromWire s
      pure (Text.pack name, D.makeRecordField item)
fromWire (Optional s) value = do
  (name,payload) <- variant value
  case (name,payload) of
    ("None", Nothing) -> Right (D.App D.None (project s))
    ("Some", Just item) -> D.Some <$> fromWire s item
    _ -> Left "Expected None or Some with one value"
fromWire shape@(Union arms) value = do
  (name,payload) <- variant value
  let selected = D.Field (project shape) (D.makeFieldSelection name)
  case (lookup (Text.unpack name) arms, payload) of
    (Just Nothing, Nothing) -> Right selected
    (Just (Just s), Just item) -> D.App selected <$> fromWire s item
    _ -> Left "Unknown union alternative or incorrect payload"
fromWire _ _ = Left "Wire value does not match the expected shape"

exactFields :: [Text] -> Value -> Either String (Keys.KeyMap Value)
exactFields expected (Object values) = do
  unless (sort expected == sort (map Key.toText (Keys.keys values)))
    (Left ("Expected fields: " ++ show expected))
  pure values
exactFields _ _ = Left "Expected object"

requireField :: Text -> Keys.KeyMap Value -> Either String Value
requireField name = maybe (Left ("Missing field: " ++ Text.unpack name)) Right . Keys.lookup (Key.fromText name)

variant :: Value -> Either String (Text, Maybe Value)
variant value@(Object values) = do
  let payload = Keys.lookup "value" values
  _ <- exactFields (case payload of Nothing -> ["tag"]; Just _ -> ["tag", "value"]) value
  name <- requireField "tag" values
  case name of
    String text -> Right (text,payload)
    _ -> Left "Expected string tag"
variant _ = Left "Expected tagged object"

project :: Shape -> D.Expr Src Void
project (Scalar TextScalar) = D.Text
project (Scalar IntegerScalar) = D.Integer
project (Scalar BoolScalar) = D.Bool
project (Scalar ProbabilityScalar) = D.Natural
project (Reference _) = D.Text
project (List s) = D.App D.List (project s)
project (Optional s) = D.App D.Optional (project s)
project (Record fields) = D.Record (Map.fromList
  [(Text.pack name, D.makeRecordField (project s)) | (name,s) <- fields])
project (Union arms) = D.Union (Map.fromList
  [(Text.pack name, project <$> payload) | (name,payload) <- arms])

decodeValueSource :: Shape -> Text -> Either [Diagnostic] Value
decodeValueSource contract source = do
  parsed <- first (problem "dhall.parse" . show) (Parser.exprFromText "fact contents" source)
  closed <- traverse (const (Left (problem "dhall.import" "Fact contents must be self-contained; imports are not supported"))) parsed
  checkedValue contract closed
  where
    problem code message = [errorDiagnostic code message]

checkedValue :: Shape -> D.Expr Src Void -> Either [Diagnostic] Value
checkedValue contract closed = do
  _ <- first (problem "dhall.type" . show)
    (TypeCheck.typeOf (D.Annot closed (project contract)))
  value <- first (problem "dhall.internal-conversion") (toWire contract (D.normalize closed))
  pure value
  where
    problem code message = [errorDiagnostic code message]

toWire :: Shape -> D.Expr Src Void -> Either String Value
toWire (Scalar TextScalar) (D.TextLit (D.Chunks [] text)) = Right (toJSON text)
toWire (Reference _) value = toWire (Scalar TextScalar) value
toWire (Scalar IntegerScalar) (D.IntegerLit n) = Right (toJSON (show n))
toWire (Scalar BoolScalar) (D.BoolLit b) = Right (toJSON b)
toWire (Scalar ProbabilityScalar) (D.NaturalLit n)
  | n <= 10000 = Right (toJSON (show n))
  | otherwise = Left "Expected probability basis points in 0..10000"
toWire (List s) (D.ListLit _ values) = toJSON <$> traverse (toWire s) (toList values)
toWire (Optional _) (D.App D.None _) = Right (tagged "None" Nothing)
toWire (Optional s) (D.Some value) = tagged "Some" . Just <$> toWire s value
toWire (Record fields) (D.RecordLit values) = object <$> traverse field fields
  where
    field (name,s) = do
      value <- maybe (Left ("Missing normalized field: " ++ name)) Right (Map.lookup (Text.pack name) values)
      result <- toWire s (D.recordFieldValue value)
      pure (Key.fromString name .= result)
toWire (Union arms) (D.Field (D.Union _) selection) = do
  let name = D.fieldSelectionLabel selection
  case lookup (Text.unpack name) arms of
    Just Nothing -> Right (tagged name Nothing)
    _ -> Left "Unexpected nullary union alternative"
toWire (Union arms) (D.App (D.Field (D.Union _) selection) value) = do
  let name = D.fieldSelectionLabel selection
  case lookup (Text.unpack name) arms of
    Just (Just s) -> tagged name . Just <$> toWire s value
    _ -> Left "Unexpected union payload"
toWire _ _ = Left "Unexpected normalized Dhall value for checked shape"

tagged :: Text -> Maybe Value -> Value
tagged name Nothing = object ["tag" .= name]
tagged name (Just value) = object ["tag" .= name, "value" .= value]
