module Kyyn.Runtime.Query (executeQuery) where

import Kyyn.Runtime.Json
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.Query (Query(..), ReadAccess(..), runLocally)
import Text.JSON.Types (JSValue(..))

executeQuery :: Codec root -> Codec args -> Codec result -> (args -> Query root result)
  -> String -> Either String String
executeQuery rootCodec argumentCodec resultCodec selected input = do
  values <- parseValue input >>= fields ["root", "arguments"]
  root <- field "root" rootCodec values
  arguments <- field "arguments" argumentCodec values
  let Query program = selected arguments
      (result, trace) = runLocally root program
  printValue (record [("result", encodeWith resultCodec result),
    ("trace", JSArray (map encodeAccess trace))])
  where
    encodeAccess (CollectionRead collection) = record
      [("tag", encodeWith stringCodec "Collection"), ("collection", encodeWith stringCodec collection)]
    encodeAccess (FactRead collection (FactId identity)) = record
      [("tag", encodeWith stringCodec "Fact"), ("collection", encodeWith stringCodec collection),
       ("factId", encodeWith stringCodec identity)]
