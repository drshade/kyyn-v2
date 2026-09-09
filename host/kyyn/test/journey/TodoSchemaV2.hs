module TodoSchemaV2 where

import Kyyn.Types.Fact (Fact)
import Kyyn.Types.SchemaMetadata

data Status = Open | Done deriving (Eq, Show)
data Todo = Todo { title :: String, status :: Status } deriving (Eq, Show)
data Root = Root { todos :: [Fact Todo] } deriving (Eq, Show)

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "todos" "todos" []]
