module OutputQueries (Arguments, Result, count, metadata) where

import Kyyn.Schema (SchemaMetadata(..))
import Kyyn.Types.Query (Query, readCollection)
import qualified KyynQueryBindings as Collections
import Main (Root)

type Arguments = ()
type Result = Integer

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] []

count :: Arguments -> Query Root Result
count () = toInteger . length <$> readCollection Collections.items
