{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value, eitherDecodeStrict')
import qualified Data.Text.Encoding as Text
import Data.Text (Text)
import Effectful (runPureEff)
import Kyyn.Domain.DataType
import Kyyn.Plumbing.Capability.DhallHandling
import Kyyn.Plumbing.Capability.SchemaInspection.Contract
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Types.SchemaMetadata

main :: IO ()
main = do
  contract <- either (fail . show) pure (checkContract root (SchemaMetadata [] [] []))
  expected <- either fail pure (eitherDecodeStrict' (Text.encodeUtf8 expectedJson) :: Either String Value)
  let result = runPureEff (runDhallHandling (decodeValue contract source))
  checked <- either (fail . show) pure result
  unless (wireValue checked == expected) (fail (show (wireValue checked)))
  unless (valueContract checked == contractId contract) (fail "lost contract identity")
  forM_ invalid $ \contents -> case runPureEff (runDhallHandling (decodeValue contract contents)) of
    Left _ -> pure ()
    Right _ -> fail ("Accepted invalid input: " ++ show contents)
  empty <- either (fail . show) pure (runPureEff (runDhallHandling (decodeValue contract emptySource)))
  expectedEmpty <- either fail pure (eitherDecodeStrict' (Text.encodeUtf8 emptyJson) :: Either String Value)
  unless (wireValue empty == expectedEmpty) (fail (show (wireValue empty)))
  collectionContract <- either (fail . show) pure
    (checkContract collectionRoot (SchemaMetadata [] [] [CollectionDecl "items" "items" [("parent", "items")]]))
  collectionValue <- either (fail . show) pure (runPureEff (runDhallHandling (decodeValue collectionContract collectionSource)))
  expectedCollection <- either fail pure (eitherDecodeStrict' (Text.encodeUtf8 collectionJson) :: Either String Value)
  unless (wireValue collectionValue == expectedCollection) (fail (show (wireValue collectionValue)))
  putStrLn "Dhall projection, typed decoding, wire conversion and pure interpreter passed."

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
