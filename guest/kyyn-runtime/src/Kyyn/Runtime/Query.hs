module Kyyn.Runtime.Query (executeQuery) where

import Kyyn.Runtime.Json
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.Query (Query(..), ReadAccess(..), runLocally)
import Data.Aeson (Value, toJSON)

executeQuery :: Codec root -> Codec args -> Codec result -> (args -> Query root result)
  -> Value -> Value -> Either String Value
executeQuery rootCodec argumentCodec resultCodec selected rootValue argumentValue = do
  root <- decodeWith rootCodec rootValue
  arguments <- decodeWith argumentCodec argumentValue
  let Query program = selected arguments
      (result, trace) = runLocally root program
  pure (record [("result", encodeWith resultCodec result),
    ("trace", toJSON (map encodeAccess trace))])
  where
    encodeAccess (CollectionRead collection) = record
      [("tag", encodeWith stringCodec "Collection"), ("collection", encodeWith textCodec collection)]
    encodeAccess (FactRead collection (FactId identity)) = record
      [("tag", encodeWith stringCodec "Fact"), ("collection", encodeWith textCodec collection),
       ("factId", encodeWith textCodec identity)]
