module SchemaV2 where
import Kyyn.Schema (Fact)
data Todo = Todo { title :: String, done :: Bool } deriving (Eq, Show)
data Root = Root { todos :: [Fact Todo] } deriving (Eq, Show)
