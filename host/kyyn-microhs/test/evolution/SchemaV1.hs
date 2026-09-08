module SchemaV1 where
import Kyyn.Types.Fact (Fact)
data Todo = Todo { title :: String } deriving (Eq, Show)
data Root = Root { todos :: [Fact Todo] } deriving (Eq, Show)
