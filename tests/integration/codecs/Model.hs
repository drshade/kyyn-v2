module Model where

type Label = String
data Box a = Box { contents :: a }
data Status = Open | Blocked String | Done
data Choice = Missing | Detailed { title :: String, count :: Integer }
data Todo = Todo
  { name :: Label
  , status :: Status
  , note :: Maybe (Maybe String)
  , budget :: Integer
  , choice :: Choice
  }
data Root = Root { todos :: [Box Todo], enabled :: Bool }
type RootAlias = Root
