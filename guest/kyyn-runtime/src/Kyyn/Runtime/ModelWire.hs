module Kyyn.Runtime.ModelWire (conversationCodec, replyCodec, valueCodec, textCodec, pairCodec) where

import qualified Agentic.Core as A
import qualified Agentic.Runtime as A
import qualified Agentic.Schema as S
import qualified Agentic.Value as A
import qualified Data.Text as T
import Kyyn.Runtime.Json
import Text.JSON.Types (JSValue)

mapped :: (a -> b) -> (b -> a) -> Codec a -> Codec b
mapped forward backward codec = Codec (encodeWith codec . backward) (fmap forward . decodeWith codec)

textCodec :: Codec T.Text
textCodec = mapped T.pack T.unpack stringCodec

pairCodec :: String -> Codec a -> String -> Codec b -> Codec (a,b)
pairCodec left a right b = Codec
  (\(x,y) -> record [(left,encodeWith a x),(right,encodeWith b y)])
  (\v -> do
    fs <- fields [left,right] v
    (,) <$> field left a fs <*> field right b fs)

payload :: String -> Codec a -> a -> JSValue
payload name codec = tagged name . Just . encodeWith codec

-- Library values include raw provider responses, independent of public KB schemas.
valueCodec :: Codec A.Value
valueCodec = Codec encode decode
  where
    encode value = case value of
      A.Null -> tagged "Null" Nothing
      A.Bool b -> payload "Bool" boolCodec b
      A.Integer n -> payload "Integer" integerCodec n
      A.Number n -> payload "Number" stringCodec (show n)
      A.String s -> payload "String" textCodec s
      A.Array xs -> payload "Array" (listCodec valueCodec) xs
      A.Object xs -> payload "Object" (listCodec (pairCodec "key" textCodec "value" valueCodec)) xs
    decode v = do
      (kind,p) <- variant v
      case (kind,p) of
        ("Null",Nothing) -> Right A.Null
        ("Bool",Just x) -> A.Bool <$> decodeWith boolCodec x
        ("Integer",Just x) -> A.Integer <$> decodeWith integerCodec x
        ("Number",Just x) -> do
          s <- decodeWith stringCodec x
          case reads s of
            [(n,"")] | not (isNaN n || isInfinite n) -> Right (A.Number n)
            _ -> Left "Invalid finite model number"
        ("String",Just x) -> A.String <$> decodeWith textCodec x
        ("Array",Just x) -> A.Array <$> decodeWith (listCodec valueCodec) x
        ("Object",Just x) -> A.Object <$> decodeWith (listCodec (pairCodec "key" textCodec "value" valueCodec)) x
        _ -> Left "Invalid model value"

schemaCodec :: Codec S.Schema
schemaCodec = Codec (\(S.Schema title doc checks shape) -> record
  [("title",encodeWith (optionalCodec textCodec) title),("doc",encodeWith (optionalCodec textCodec) doc),
   ("checks",encodeWith (listCodec textCodec) checks),("shape",encodeWith shapeCodec shape)])
  (\v -> do
    fs <- fields ["title","doc","checks","shape"] v
    S.Schema <$> field "title" (optionalCodec textCodec) fs <*> field "doc" (optionalCodec textCodec) fs
      <*> field "checks" (listCodec textCodec) fs <*> field "shape" shapeCodec fs)

shapeCodec :: Codec S.Shape
shapeCodec = Codec encode decode
  where
    encode shape = case shape of
      S.SObject fs -> payload "Object" (listCodec fieldCodec) fs
      S.SSum vs -> payload "Sum" (listCodec variantCodec) vs
      S.SEnum options -> payload "Enum" (listCodec enumCodec) options
      S.SArray inner -> payload "Array" schemaCodec inner
      S.SNullable inner -> payload "Nullable" schemaCodec inner
      S.SString format -> payload "String" (optionalCodec formatCodec) format
      S.SInteger -> tagged "Integer" Nothing
      S.SNumber -> tagged "Number" Nothing
      S.SBool -> tagged "Bool" Nothing
      S.SNull -> tagged "Null" Nothing
    decode v = do
      (kind,p) <- variant v
      case (kind,p) of
        ("Object",Just x) -> S.SObject <$> decodeWith (listCodec fieldCodec) x
        ("Sum",Just x) -> S.SSum <$> decodeWith (listCodec variantCodec) x
        ("Enum",Just x) -> S.SEnum <$> decodeWith (listCodec enumCodec) x
        ("Array",Just x) -> S.SArray <$> decodeWith schemaCodec x
        ("Nullable",Just x) -> S.SNullable <$> decodeWith schemaCodec x
        ("String",Just x) -> S.SString <$> decodeWith (optionalCodec formatCodec) x
        ("Integer",Nothing) -> Right S.SInteger
        ("Number",Nothing) -> Right S.SNumber
        ("Bool",Nothing) -> Right S.SBool
        ("Null",Nothing) -> Right S.SNull
        _ -> Left "Invalid model schema"
    enumCodec = pairCodec "label" textCodec "doc" (optionalCodec textCodec)
    formatCodec = Codec (encodeWith stringCodec . show) (\v -> do
      name <- decodeWith stringCodec v
      maybe (Left "Invalid model schema format") Right
        (lookup name [(show f,f) | f <- [S.DateTime,S.Date,S.Email,S.Uri,S.Uuid]]))

fieldCodec :: Codec S.Field
fieldCodec = Codec (\(S.Field name schema required) -> record
  [("name",encodeWith textCodec name),("schema",encodeWith schemaCodec schema),("required",encodeWith boolCodec required)])
  (\v -> do
    fs <- fields ["name","schema","required"] v
    S.Field <$> field "name" textCodec fs <*> field "schema" schemaCodec fs <*> field "required" boolCodec fs)

variantCodec :: Codec S.Variant
variantCodec = Codec (\(S.Variant name doc fs) -> record
  [("name",encodeWith textCodec name),("doc",encodeWith (optionalCodec textCodec) doc),("fields",encodeWith (listCodec fieldCodec) fs)])
  (\v -> do
    fs <- fields ["name","doc","fields"] v
    S.Variant <$> field "name" textCodec fs <*> field "doc" (optionalCodec textCodec) fs <*> field "fields" (listCodec fieldCodec) fs)

conversationCodec :: Codec A.Conversation
conversationCodec = Codec (\(A.Conversation path instruction state stateSchema tools output history) -> record
  [("path",encodeWith (listCodec noteCodec) path),
   ("instruction",encodeWith textCodec (A.instructionText instruction)),("state",encodeWith valueCodec state),
   ("stateSchema",encodeWith schemaCodec stateSchema),("tools",encodeWith (listCodec toolCodec) tools),
   ("output",encodeWith schemaCodec output),("history",encodeWith (listCodec exchangeCodec) history)])
  (\v -> do
    fs <- fields ["path","instruction","state","stateSchema","tools","output","history"] v
    A.Conversation <$> field "path" (listCodec noteCodec) fs <*> (A.Instruction <$> field "instruction" textCodec fs)
      <*> field "state" valueCodec fs <*> field "stateSchema" schemaCodec fs
      <*> field "tools" (listCodec toolCodec) fs <*> field "output" schemaCodec fs <*> field "history" (listCodec exchangeCodec) fs)
  where
    noteCodec = mapped (uncurry A.Note) (\(A.Note n d) -> (n,d)) (pairCodec "name" textCodec "description" (optionalCodec textCodec))
    toolCodec = Codec (\(A.ToolSpec n d s) -> record
      [("name",encodeWith textCodec n),("description",encodeWith textCodec d),("input",encodeWith schemaCodec s)])
      (\v -> do
        fs <- fields ["name","description","input"] v
        A.ToolSpec <$> field "name" textCodec fs <*> field "description" textCodec fs <*> field "input" schemaCodec fs)

rawCodec :: Codec A.Raw
rawCodec = mapped A.Raw (\(A.Raw v) -> v) valueCodec

exchangeCodec :: Codec A.Exchange
exchangeCodec = Codec encode decode
  where
    called = pairCodec "raw" rawCodec "results" (listCodec (pairCodec "id" textCodec "result" resultCodec))
    rejected = pairCodec "raw" rawCodec "reason" textCodec
    encode (A.Called raw results) = payload "Called" called (raw,results)
    encode (A.Rejected raw reason) = payload "Rejected" rejected (raw,reason)
    decode v = do
      (kind,p) <- variant v
      case (kind,p) of
        ("Called",Just x) -> uncurry A.Called <$> decodeWith called x
        ("Rejected",Just x) -> uncurry A.Rejected <$> decodeWith rejected x
        _ -> Left "Invalid model exchange"
    resultCodec = Codec (\r -> case r of
      A.ToolOk v -> payload "Ok" valueCodec v
      A.ToolFailed t -> payload "Failed" textCodec t) (\v -> do
        (kind,p) <- variant v
        case (kind,p) of
          ("Ok",Just x) -> A.ToolOk <$> decodeWith valueCodec x
          ("Failed",Just x) -> A.ToolFailed <$> decodeWith textCodec x
          _ -> Left "Invalid model tool result")

replyCodec :: Codec (Either String A.Turn)
replyCodec = Codec (either (payload "Left" stringCodec) (payload "Right" turnCodec)) (\v -> do
  (kind,p) <- variant v
  case (kind,p) of
    ("Left",Just x) -> Left <$> decodeWith stringCodec x
    ("Right",Just x) -> Right <$> decodeWith turnCodec x
    _ -> Left "Invalid model response")

turnCodec :: Codec A.Turn
turnCodec = mapped (uncurry A.Turn) (\(A.Turn r a) -> (r,a)) (pairCodec "raw" rawCodec "action" actionCodec)
  where
    actionCodec = Codec (\a -> case a of
      A.Respond v -> payload "Respond" valueCodec v
      A.CallTools cs -> payload "CallTools" (listCodec callCodec) cs) (\v -> do
        (kind,p) <- variant v
        case (kind,p) of
          ("Respond",Just x) -> A.Respond <$> decodeWith valueCodec x
          ("CallTools",Just x) -> A.CallTools <$> decodeWith (listCodec callCodec) x
          _ -> Left "Invalid model action")
    callCodec = Codec (\(A.ToolCall identity name input) -> record
      [("id",encodeWith textCodec identity),("name",encodeWith textCodec name),("input",encodeWith valueCodec input)])
      (\v -> do
        fs <- fields ["id","name","input"] v
        A.ToolCall <$> field "id" textCodec fs <*> field "name" textCodec fs <*> field "input" valueCodec fs)
