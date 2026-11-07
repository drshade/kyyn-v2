module Kyyn.Plumbing.Protocol.Query (decodeQueryReply) where

import Control.Monad (unless)
import Data.Aeson (Value, eitherDecodeStrict, withObject, withArray, (.:))
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.Foldable (toList)
import Data.List (sort, intercalate)
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.Query (ReadAccess(..))

decodeQueryReply :: Bytes.ByteString -> Either String (Value, [ReadAccess])
decodeQueryReply bytes = eitherDecodeStrict bytes >>= parseEither
  (withObject "QueryReply" $ \o -> do
    unless (sort (Keys.keys o) == ["result", "trace"]) (fail "Expected result and trace")
    value <- o .: "result"
    trace <- o .: "trace" >>= withArray "ReadTrace" (traverse access . toList)
    pure (value, trace))
  where
    access = withObject "ReadAccess" $ \o -> do
      kind <- o .: "tag"
      case kind :: String of
        "Collection" | sort (Keys.keys o) == ["collection", "tag"] -> CollectionRead <$> o .: "collection"
        "Fact" | sort (Keys.keys o) == ["collection", "factId", "tag"] ->
          FactRead <$> o .: "collection" <*> (FactId <$> o .: "factId")
        _ -> fail ("Invalid read access: " ++ intercalate ", " (map show (Keys.keys o)))
