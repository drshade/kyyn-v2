{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling) where

import Data.Bifunctor (first)
import Data.Aeson (Value, object, (.=), toJSON)
import qualified Data.Aeson.Key as Key
import Data.Foldable (toList)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Void (Void)
import qualified Dhall.Core as D
import qualified Dhall.Map as Map
import qualified Dhall.Parser as Parser
import Dhall.Src (Src)
import qualified Dhall.TypeCheck as TypeCheck
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Plumbing.Capability.SchemaInspection.Contract
  ( CheckedContract, contractId, contractShape )

import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling(..), CheckedDhallValue(..))

runDhallHandling :: Eff (DhallHandling : es) a -> Eff es a
runDhallHandling = interpret $ \_ -> \case
  DecodeValue contract contents -> pure (decodeValueSource contract contents)

projectDhallType :: CheckedContract -> D.Expr Src Void
projectDhallType = project . contractShape

project :: Shape -> D.Expr Src Void
project (Scalar TextScalar) = D.Text
project (Scalar IntegerScalar) = D.Integer
project (Scalar BoolScalar) = D.Bool
project (Reference _) = D.Text
project (List s) = D.App D.List (project s)
project (Optional s) = D.App D.Optional (project s)
project (Record fields) = D.Record (Map.fromList
  [(Text.pack name, D.makeRecordField (project s)) | (name,s) <- fields])
project (Union arms) = D.Union (Map.fromList
  [(Text.pack name, project <$> payload) | (name,payload) <- arms])

decodeValueSource :: CheckedContract -> Text -> Either [Diagnostic] CheckedDhallValue
decodeValueSource contract source = do
  parsed <- first (problem "dhall.parse" . show) (Parser.exprFromText "fact contents" source)
  closed <- traverse (const (Left (problem "dhall.import" "Fact contents must be self-contained; imports are not supported"))) parsed
  _ <- first (problem "dhall.type" . show)
    (TypeCheck.typeOf (D.Annot closed (projectDhallType contract)))
  value <- first (problem "dhall.internal-conversion") (toWire (contractShape contract) (D.normalize closed))
  pure (CheckedDhallValue (contractId contract) value)
  where
    problem code message = [Diagnostic code message]

toWire :: Shape -> D.Expr Src Void -> Either String Value
toWire (Scalar TextScalar) (D.TextLit (D.Chunks [] text)) = Right (toJSON text)
toWire (Reference _) value = toWire (Scalar TextScalar) value
toWire (Scalar IntegerScalar) (D.IntegerLit n) = Right (toJSON (show n))
toWire (Scalar BoolScalar) (D.BoolLit b) = Right (toJSON b)
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
