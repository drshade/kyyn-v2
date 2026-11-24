{-# LANGUAGE FlexibleContexts, ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Interactive.Query (LiveQueryRef, liveQueryRef, liveQuery) where

import qualified Agentic as A
import qualified Agentic.Codec as C
import qualified Agentic.Schema as S
import qualified Agentic.Value as V
import Control.Monad.Trans.Except (ExceptT(..), throwE)
import qualified Data.Aeson as Json
import qualified Data.ByteString.Lazy as Bytes
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Contract
import Kyyn.Plugin.Live (LiveQueryProgram)
import Kyyn.Types.Plugin (ConnectorInstance(..), FetchError(..))
import Kyyn.Types.LiveQuery
import Kyyn.Types.Program (Program, Member, inject, request)

data LiveQueryRef input output = LiveQueryRef LiveQueryBinding
  (Either ProjectionError (CompiledContract input, CompiledContract output))

liveQueryRef :: forall config input output connector. (Contract input, Contract output)
  => Text -> Text -> Text -> (config -> input -> LiveQueryProgram (Either FetchError output))
  -> ConnectorInstance connector -> LiveQueryRef input output
liveQueryRef plugin connector method _ (ConnectorInstance name) =
  LiveQueryRef (LiveQueryBinding plugin connector name method)
    ((,) <$> compileContract (contract @input) <*> compileContract (contract @output))

liveQuery :: Member LiveQueryCall calls => LiveQueryRef input output
  -> A.Agentic (ExceptT FetchError (Program calls)) input output
liveQuery (LiveQueryRef binding contracts) = case contracts of
  Left problem -> A.act (\_ -> throwE (FetchError (Text.pack (show problem))))
  Right (input,output) -> A.durablyWith (requestCodec binding input output) output.codec $ \key value -> do
    case key of
      Nothing -> throwE (FetchError "liveQuery requires hosted interactive execution")
      Just _ -> pure ()
    result <- ExceptT (request (inject (InvokeLiveQuery binding input.description output.description (input.codec.encode value))))
    either (throwE . FetchError) pure (output.codec.decode result)

requestCodec :: LiveQueryBinding -> CompiledContract input -> CompiledContract output -> C.Codec input
requestCodec binding input output = C.Codec schema encode decode
  where
    identity = Text.decodeUtf8 (Bytes.toStrict (Json.encode (binding,input.description,output.description)))
    schema = S.schemaOf (S.SObject [S.Field "binding" (S.schemaOf (S.SString Nothing)) True,
      S.Field "input" input.codec.schema True])
    encode value = V.Object [("binding",V.String identity),("input",input.codec.encode value)]
    decode (V.Object fields) | length fields == 2, Just (V.String actual) <- lookup "binding" fields,
      actual == identity, Just value <- lookup "input" fields = input.codec.decode value
    decode _ = Left "Live query binding or contracts differ from the captured reference"
