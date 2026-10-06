{-# LANGUAGE GADTs, OverloadedStrings, OverloadedRecordDot #-}
module Bridge where

import qualified Agentic as A
import qualified Agentic.Runtime as A
import Agentic.Runtime (Runtime(..))
import qualified Agentic.Schema as S
import qualified Data.Text as T
import Control.Monad.Trans.Except (ExceptT, throwE)
import Control.Monad.Trans.Class (lift)
import Kyyn.Types.Program (Program, request)
import qualified Kyyn.Runtime.Json as J
import Kyyn.Runtime.Plugin (exchange)
import Kyyn.Runtime.Transport (Transport)
import Text.JSON.Types (JSValue)

-- Proof-only single-turn capability. No provider IO or credentials in the flow.
data Model result where
  Turn :: A.Conversation -> Model (Either String A.Turn)

type Guest = ExceptT String (Program Model)

runtime :: A.Runtime Guest
runtime = (A.runtimeWith (throwE . show))
  { systemTwo = A.SystemTwo $ \conversation ->
      lift (request (Turn conversation)) >>= either throwE pure }

modelRequest :: Transport -> Integer -> Model a -> IO a
modelRequest transport identity (Turn conversation) =
  exchange transport identity "model" "turn" (conversationValue conversation) replyCodec

-- A lossless tagged transport for the library's internal Value, not KB schema.
valueCodec :: J.Codec A.Value
valueCodec = J.Codec encode decode
  where
    encode value = case value of
      A.Null -> J.tagged "Null" Nothing
      A.Bool b -> tag "Bool" (J.encodeWith J.boolCodec b)
      A.Integer n -> tag "Integer" (J.encodeWith J.integerCodec n)
      A.Number n -> tag "Number" (text (show n))
      A.String s -> tag "String" (text (T.unpack s))
      A.Array xs -> tag "Array" (J.encodeWith (J.listCodec valueCodec) xs)
      A.Object xs -> tag "Object" (J.encodeWith (J.listCodec pairCodec) xs)
    decode v = do
      (kind,payload) <- J.variant v
      case (kind,payload) of
        ("Null",Nothing) -> Right A.Null
        ("Bool",Just x) -> A.Bool <$> J.decodeWith J.boolCodec x
        ("Integer",Just x) -> A.Integer <$> J.decodeWith J.integerCodec x
        ("Number",Just x) -> do
          s <- J.decodeWith J.stringCodec x
          case reads s of
            [(n,"")] | not (isNaN n || isInfinite n) -> Right (A.Number n)
            _ -> Left "Invalid finite model number"
        ("String",Just x) -> A.String . T.pack <$> J.decodeWith J.stringCodec x
        ("Array",Just x) -> A.Array <$> J.decodeWith (J.listCodec valueCodec) x
        ("Object",Just x) -> A.Object <$> J.decodeWith (J.listCodec pairCodec) x
        _ -> Left "Invalid model value"
    pairCodec = J.Codec (\(key,v) -> J.record [("key",text (T.unpack key)),("value",encode v)])
      (\v -> do
        fs <- J.fields ["key","value"] v
        (,) <$> (T.pack <$> J.field "key" J.stringCodec fs) <*> J.field "value" valueCodec fs)
    tag k v = J.tagged k (Just v)

text :: String -> JSValue
text = J.encodeWith J.stringCodec

replyCodec :: J.Codec (Either String A.Turn)
replyCodec = J.Codec (const (error "Host reply decoder only")) $ \value -> do
  (kind,payload) <- J.variant value
  case (kind,payload) of
    ("Left",Just message) -> Left <$> J.decodeWith J.stringCodec message
    ("Right",Just result) -> do
      fs <- J.fields ["raw","action"] result
      raw <- A.Raw <$> J.field "raw" valueCodec fs
      action <- J.field "action" actionCodec fs
      pure (Right (A.Turn raw action))
    _ -> Left "Invalid model response"
  where
    actionCodec = J.Codec (const (error "Response decoder only")) $ \value -> do
      (kind,payload) <- J.variant value
      case (kind,payload) of
        ("Respond",Just result) -> A.Respond <$> J.decodeWith valueCodec result
        ("CallTools",Just calls) -> A.CallTools <$> J.decodeWith (J.listCodec callCodec) calls
        _ -> Left "Invalid model action"
    callCodec = J.Codec (const (error "Tool call decoder only")) $ \value -> do
      fs <- J.fields ["id","name","input"] value
      A.ToolCall <$> (T.pack <$> J.field "id" J.stringCodec fs)
        <*> (T.pack <$> J.field "name" J.stringCodec fs) <*> J.field "input" valueCodec fs

conversationValue :: A.Conversation -> JSValue
conversationValue c = J.record
  [("instruction",text (T.unpack (c.instruction.text))),
   ("state",value (c.input)),("stateSchema",schema (c.inputSchema)),
   ("output",schema (c.outputSchema)),
   ("tools",J.encodeWith (J.listCodec toolCodec) (c.tools)),
   ("history",J.encodeWith (J.listCodec historyCodec) (c.history))]
  where
    value = J.encodeWith valueCodec
    toolCodec = J.Codec (\(A.ToolSpec name description input) -> J.record
      [("name",text (T.unpack name)),("description",text (T.unpack description)),("input",schema input)])
      (const (Left "Outbound tool description"))
    historyCodec = J.Codec encodeHistory (const (Left "Outbound history"))
    encodeHistory (A.Rejected (A.Raw raw) reason) = J.tagged "Rejected" (Just (J.record
      [("raw",value raw),("reason",text (T.unpack reason))]))
    encodeHistory (A.Called (A.Raw raw) results) = J.tagged "Called" (Just (J.record
      [("raw",value raw),("results",J.encodeWith (J.listCodec resultCodec) results)]))
    resultCodec = J.Codec (\(key,result) -> J.record [("id",text (T.unpack key)),("result",toolResult result)])
      (const (Left "Outbound result"))
    toolResult (A.ToolOk v) = J.tagged "Ok" (Just (value v))
    toolResult (A.ToolFailed message) = J.tagged "Failed" (Just (text (T.unpack message)))

schema :: S.Schema -> JSValue
schema s = J.record [("title",maybeText (s.title)),("doc",maybeText (s.doc)),
  ("checks",J.encodeWith (J.listCodec J.stringCodec) (map T.unpack (s.checks))),
  ("shape",shape (s.shape))]
  where
    maybeText = J.encodeWith (J.optionalCodec J.stringCodec) . fmap T.unpack
    list f xs = J.encodeWith (J.listCodec (J.Codec f (const (Left "Outbound schema")))) xs
    tagged name = J.tagged name . Just
    field (S.Field name inner required) = J.record
      [("name",text (T.unpack name)),("schema",schema inner),("required",J.encodeWith J.boolCodec required)]
    variant (S.Variant name doc fs) = J.record
      [("name",text (T.unpack name)),("doc",maybeText doc),("fields",list field fs)]
    shape sh = case sh of
      S.SObject fs -> tagged "Object" (list field fs)
      S.SSum vs -> tagged "Sum" (list variant vs)
      S.SEnum options -> tagged "Enum" (list (\(label,doc) -> J.record
        [("label",text (T.unpack label)),("doc",maybeText doc)]) options)
      S.SArray inner -> tagged "Array" (schema inner)
      S.SNullable inner -> tagged "Nullable" (schema inner)
      S.SString format -> tagged "String" (J.encodeWith (J.optionalCodec J.stringCodec) (fmap show format))
      S.SInteger -> J.tagged "Integer" Nothing
      S.SNumber -> J.tagged "Number" Nothing
      S.SBool -> J.tagged "Bool" Nothing
      S.SNull -> J.tagged "Null" Nothing
