module SchemaV1 where
import Kyyn.Schema (Fact)
data Todo = Todo { title :: String } deriving (Eq, Show)
data Root = Root { todos :: [Fact Todo] } deriving (Eq, Show)
