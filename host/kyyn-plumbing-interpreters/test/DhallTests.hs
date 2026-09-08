{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..), eitherDecodeStrict', object, (.=))
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.Text.Encoding as Text
import Data.Text (Text)
import Effectful (runPureEff)
import Kyyn.Domain.DataType
import Kyyn.Plumbing.Capability.DhallHandling
import Kyyn.Domain.Contract
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Types.SchemaMetadata

main :: IO ()
main = do
  contract <- either (fail . show) pure (checkContract root (SchemaMetadata [] [] []))
  expected <- either fail pure (eitherDecodeStrict' (Text.encodeUtf8 expectedJson) :: Either String Value)
  let result = runPureEff (runDhallHandling (decodeValue (contractShape contract) source))
  checked <- either (fail . show) pure result
  unless (checked == expected) (fail (show (checked)))
  forM_ invalid $ \contents -> case runPureEff (runDhallHandling (decodeValue (contractShape contract) contents)) of
    Left _ -> pure ()
    Right _ -> fail ("Accepted invalid input: " ++ show contents)
  empty <- either (fail . show) pure (runPureEff (runDhallHandling (decodeValue (contractShape contract) emptySource)))
  expectedEmpty <- either fail pure (eitherDecodeStrict' (Text.encodeUtf8 emptyJson) :: Either String Value)
  unless (empty == expectedEmpty) (fail (show (empty)))
  collectionContract <- either (fail . show) pure
    (checkContract collectionRoot (SchemaMetadata [] [] [CollectionDecl "items" "items" [("parent", "items")]]))
  collectionValue <- either (fail . show) pure (runPureEff (runDhallHandling (decodeValue (contractShape collectionContract) collectionSource)))
  expectedCollection <- either fail pure (eitherDecodeStrict' (Text.encodeUtf8 collectionJson) :: Either String Value)
  unless (collectionValue == expectedCollection) (fail (show (collectionValue)))
  forM_ [expected, expectedEmpty, set "title" (String "quote: \" slash: \\ newline:\n${notAnImport} 🌍") expected] $
    roundTrip contract
  roundTrip collectionContract expectedCollection
  roundTrip collectionContract (object ["items" .= ([] :: [Value])])
  forM_ badWire $ \value -> case runPureEff (runDhallHandling (encodeValue (contractShape contract) value)) of
    Left _ -> pure ()
    Right _ -> fail ("Encoded invalid wire value: " ++ show value)
  forM_ ["+1", "01", "-0", "1.0", " 1", "1 ", "1e3", "", "--1"] $ \number ->
    rejectEncoding contract (set "count" (String number) expected)
  forM_ [Number 42, Null, String "yes"] $ \value ->
    rejectEncoding contract (set "active" value expected)
  forM_ [object ["tag" .= ("Open" :: Text), "value" .= True]
        ,object ["tag" .= ("Done" :: Text)]
        ,object ["tag" .= ("Unknown" :: Text)]
        ,object ["tag" .= ("Open" :: Text), "extra" .= True]] $ \value ->
    rejectEncoding contract (set "status" value expected)
  forM_ [Null, object ["tag" .= ("None" :: Text), "value" .= True]
        ,object ["tag" .= ("Some" :: Text)]] $ \value ->
    rejectEncoding contract (set "note" value expected)
  putStrLn "Dhall typed decoding, checked encoding and semantic round trips passed."

roundTrip :: CheckedContract -> Value -> IO ()
roundTrip contract value = do
  rendered <- either (fail . show) pure (runPureEff (runDhallHandling (encodeValue (contractShape contract) value)))
  decoded <- either (fail . show) pure (runPureEff (runDhallHandling (decodeValue (contractShape contract) rendered)))
  unless (decoded == value)
    (fail ("Round trip changed value: " ++ show rendered))
  rerendered <- either (fail . show) pure (runPureEff (runDhallHandling (encodeValue (contractShape contract) (decoded))))
  unless (rendered == rerendered) (fail "Unstable Dhall rendering")

rejectEncoding :: CheckedContract -> Value -> IO ()
rejectEncoding contract value = case runPureEff (runDhallHandling (encodeValue (contractShape contract) value)) of
  Left _ -> pure ()
  Right _ -> fail ("Encoded invalid wire value: " ++ show value)

set :: Key -> Value -> Value -> Value
set key value (Object values) = Object (Keys.insert key value values)
set _ _ value = value

badWire :: [Value]
badWire = [Null, Number 1, String "not a root", object [], object ["extra" .= True]]

root :: DataType
root = Algebraic "Example.Root" [] [Constructor "Example.Root"
  [(Just "title", StringType), (Just "count", IntegerType), (Just "active", BoolType)
  ,(Just "note", OptionalType StringType), (Just "labels", ListType StringType)
  ,(Just "status", Algebraic "Example.Status" []
    [Constructor "Example.Open" [], Constructor "Example.Done" [(Nothing, IntegerType)]])
  ,(Just "identity", sdkFactIdType)]]

source :: Text
source = "let title = \"héllo 🌍\" in { title = title, count = -9007199254740993123456789, active = True, note = Some \"ok\", labels = [\"a\", \"b\"], status = < Open | Done : Integer >.Done +42, identity = \"todo-001\" }"

emptySource :: Text
emptySource = "{ title = \"\", count = +0, active = False, note = None Text, labels = [] : List Text, status = < Open | Done : Integer >.Open, identity = \"todo-002\" }"

expectedJson :: Text
expectedJson = "{\"title\":\"héllo 🌍\",\"count\":\"-9007199254740993123456789\",\"active\":true,\"note\":{\"tag\":\"Some\",\"value\":\"ok\"},\"labels\":[\"a\",\"b\"],\"status\":{\"tag\":\"Done\",\"value\":\"42\"},\"identity\":\"todo-001\"}"

invalid :: [Text]
invalid = ["{", "{ title = \"only one field\" }", "env:HOME", "./fact.dhall", "https://example.com/fact.dhall"
  , "let ignored = ./unused.dhall in " <> emptySource
  , "(" <> emptySource <> ") // { extra = True }"
  , "{ title = \"x\", count = 1, active = True, note = None Text, labels = [] : List Text, status = < Open | Done : Integer >.Open, identity = \"id\" }"]

emptyJson :: Text
emptyJson = "{\"title\":\"\",\"count\":\"0\",\"active\":false,\"note\":{\"tag\":\"None\"},\"labels\":[],\"status\":{\"tag\":\"Open\"},\"identity\":\"todo-002\"}"

collectionRoot :: DataType
collectionRoot = Algebraic "Example.Root" [] [Constructor "Example.Root" [(Just "items", ListType fact)]]
  where
    fact = Algebraic "Kyyn.Types.Fact.Fact" [payload]
      [Constructor "Kyyn.Types.Fact.Fact" [(Nothing, sdkFactIdType), (Nothing, payload)]]
    payload = Algebraic "Example.Payload" [] [Constructor "Example.Payload"
      [(Just "parent", OptionalType sdkFactIdType), (Just "result", result)]]
    result = Algebraic "Example.Result" []
      [Constructor "Example.Pending" [], Constructor "Example.Ready" [(Just "notes", ListType (OptionalType StringType))]]

collectionSource :: Text
collectionSource = "{ items = [{ id = \"one\", value = { parent = Some \"other\", result = < Pending | Ready : { notes : List (Optional Text) } >.Ready { notes = [Some \"hello\", None Text] } } }] }"

collectionJson :: Text
collectionJson = "{\"items\":[{\"id\":\"one\",\"value\":{\"parent\":{\"tag\":\"Some\",\"value\":\"other\"},\"result\":{\"tag\":\"Ready\",\"value\":{\"notes\":[{\"tag\":\"Some\",\"value\":\"hello\"},{\"tag\":\"None\"}]}}}}]}"
