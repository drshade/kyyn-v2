{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Types.FlowStatus
  ( FlowStatus(..), ExecutionStatus(..), FlowOutcome(..), CancelScope(..)
  , statusCodec, encodeStatus, decodeStatus, outcomeCodec, encodeOutcome, decodeOutcome ) where

import Agentic.Codec (Codec(..))
import qualified Agentic.Schema as S
import Agentic.Value (Value(..))
import Control.Monad (unless)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Types.Diagnostic (Diagnostic(Diagnostic), Severity(..), DiagnosticLocation(..))

data FlowStatus a = FlowStatus { execution :: ExecutionStatus a, outstandingWaits :: [Text] }
  deriving (Eq, Show, Functor, Foldable, Traversable)
data ExecutionStatus a = Runnable | Running | Waiting | Finished (FlowOutcome a)
  deriving (Eq, Show, Functor, Foldable, Traversable)
data FlowOutcome a = Completed a | Failed [Diagnostic] | Cancelled
  deriving (Eq, Show, Functor, Foldable, Traversable)
data CancelScope = ThisFlow | FlowAndDescendants deriving (Eq, Show)

-- The host supplies a wire-value encoder; the guest supplies the captured
-- result codec. The protocol and the journal use this same structural envelope.
statusCodec :: Codec a -> Codec (FlowStatus a)
statusCodec output = Codec (recordSchema [("execution",executionSchema output.schema),("outstandingWaits",listSchema textSchema)])
  (encodeStatus output.encode) (decodeStatus output.decode)

encodeStatus :: (a -> Value) -> FlowStatus a -> Value
encodeStatus output (FlowStatus state waits) = Object
  [("execution",case state of
      Runnable -> tag "runnable"; Running -> tag "running"; Waiting -> tag "waiting"
      Finished result -> tagged "finished" (encodeOutcome output result)),
   ("outstandingWaits",Array (map String waits))]

decodeStatus :: (Value -> Either Text a) -> Value -> Either Text (FlowStatus a)
decodeStatus output value = do
  fields <- record ["execution","outstandingWaits"] value
  state <- field "execution" fields >>= variant >>= \result -> case result of
    ("runnable",Nothing) -> Right Runnable
    ("running",Nothing) -> Right Running
    ("waiting",Nothing) -> Right Waiting
    ("finished",Just body) -> Finished <$> decodeOutcome output body
    _ -> Left "Invalid flow execution status"
  FlowStatus state <$> (field "outstandingWaits" fields >>= list text)

outcomeCodec :: Codec a -> Codec (FlowOutcome a)
outcomeCodec output = Codec (outcomeSchema output.schema) (encodeOutcome output.encode) (decodeOutcome output.decode)

encodeOutcome :: (a -> Value) -> FlowOutcome a -> Value
encodeOutcome output result = case result of
  Completed value -> tagged "completed" (output value)
  Failed problems -> tagged "failed" (Array (map encodeDiagnostic problems))
  Cancelled -> tag "cancelled"

decodeOutcome :: (Value -> Either Text a) -> Value -> Either Text (FlowOutcome a)
decodeOutcome output value = variant value >>= \outcome -> case outcome of
  ("completed",Just result) -> Completed <$> output result
  ("failed",Just problems) -> Failed <$> list decodeDiagnostic problems
  ("cancelled",Nothing) -> Right Cancelled
  _ -> Left "Invalid flow outcome"

encodeDiagnostic :: Diagnostic -> Value
encodeDiagnostic (Diagnostic severity code message location) = Object
  [("severity",String (case severity of Warning -> "warning"; Error -> "error")),("code",String code),("message",String message),
   ("location",maybe (tag "none") (tagged "some" . encodeLocation) location)]
  where
    encodeLocation (FactLocation collection ident selected) = tagged "fact" (Object
      [("collection",String collection),("id",String ident),("field",maybe (tag "none") (tagged "some" . String) selected)])
    encodeLocation (SourceLocation path line column) = tagged "source" (Object
      [("path",String path),("line",String (Text.pack (show line))),("column",String (Text.pack (show column)))])
    encodeLocation (ExampleLocation name) = tagged "example" (String name)

decodeDiagnostic :: Value -> Either Text Diagnostic
decodeDiagnostic value = do
  fields <- record ["severity","code","message","location"] value
  severity <- field "severity" fields >>= text >>= \name -> case name of
    "warning" -> Right Warning; "error" -> Right Error; _ -> Left "Invalid diagnostic severity"
  Diagnostic severity <$> (field "code" fields >>= text) <*> (field "message" fields >>= text)
    <*> (field "location" fields >>= optional location)
  where
    location value' = variant value' >>= \selected -> case selected of
      ("fact",Just body) -> do
        fields <- record ["collection","id","field"] body
        FactLocation <$> (field "collection" fields >>= text) <*> (field "id" fields >>= text)
          <*> (field "field" fields >>= optional text)
      ("source",Just body) -> do
        fields <- record ["path","line","column"] body
        SourceLocation <$> (field "path" fields >>= text) <*> (field "line" fields >>= positive)
          <*> (field "column" fields >>= positive)
      ("example",Just body) -> ExampleLocation <$> text body
      _ -> Left "Invalid diagnostic location"
    positive value' = text value' >>= \source -> case reads (Text.unpack source) of
      [(n,"")] | n > 0 && Text.pack (show (n :: Integer)) == source -> Right n
      _ -> Left "Expected positive canonical source coordinate"

executionSchema :: S.Schema -> S.Schema
executionSchema output = sumSchema
  [("runnable",Nothing),("running",Nothing),("waiting",Nothing),("finished",Just (outcomeSchema output))]
outcomeSchema :: S.Schema -> S.Schema
outcomeSchema output = sumSchema
  [("completed",Just output),("failed",Just (listSchema diagnosticSchema)),("cancelled",Nothing)]
diagnosticSchema :: S.Schema
diagnosticSchema = recordSchema [("severity",S.schemaOf (S.SEnum [("warning",Nothing),("error",Nothing)])),
  ("code",textSchema),("message",textSchema),("location",optionalSchema (sumSchema
    [("fact",Just (recordSchema [("collection",textSchema),("id",textSchema),("field",optionalSchema textSchema)])),
     ("source",Just (recordSchema [("path",textSchema),("line",textSchema),("column",textSchema)])),
     ("example",Just textSchema)]))]
textSchema :: S.Schema
textSchema = S.schemaOf (S.SString Nothing)
listSchema :: S.Schema -> S.Schema
listSchema = S.schemaOf . S.SArray
optionalSchema :: S.Schema -> S.Schema
optionalSchema schema = sumSchema [("none",Nothing),("some",Just schema)]
recordSchema :: [(Text,S.Schema)] -> S.Schema
recordSchema fields = S.schemaOf (S.SObject [S.Field name schema True | (name,schema) <- fields])
sumSchema :: [(Text,Maybe S.Schema)] -> S.Schema
sumSchema cases = S.schemaOf (S.SSum [S.Variant name Nothing (maybe [] (\schema -> [S.Field "value" schema True]) payload) | (name,payload) <- cases])

tag :: Text -> Value
tag name = Object [("tag",String name)]
tagged :: Text -> Value -> Value
tagged name value = Object [("tag",String name),("value",value)]
record :: [Text] -> Value -> Either Text [(Text,Value)]
record expected (Object fields) = do
  unless (sort (map fst fields) == sort expected) (Left "Unexpected status fields")
  Right fields
record _ _ = Left "Expected status object"
field :: Text -> [(Text,Value)] -> Either Text Value
field name = maybe (Left ("Missing status field: " <> name)) Right . lookup name
variant :: Value -> Either Text (Text,Maybe Value)
variant value@(Object fields) = do
  _ <- record (if any ((== "value") . fst) fields then ["tag","value"] else ["tag"]) value
  name <- field "tag" fields >>= text
  Right (name,lookup "value" fields)
variant _ = Left "Expected status variant"
text :: Value -> Either Text Text
text (String value) = Right value
text _ = Left "Expected text"
list :: (Value -> Either Text a) -> Value -> Either Text [a]
list decode (Array values) = traverse decode values
list _ _ = Left "Expected list"
optional :: (Value -> Either Text a) -> Value -> Either Text (Maybe a)
optional decode value = variant value >>= \selected -> case selected of
  ("none",Nothing) -> Right Nothing
  ("some",Just body) -> Just <$> decode body
  _ -> Left "Expected optional value"
