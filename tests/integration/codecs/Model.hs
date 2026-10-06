module Model where

import Data.Text (Text)

type Label = Text
data Box a = Box { contents :: a }
newtype Wrapped = Wrapped String
data Status = Open | Blocked String | Done
data Choice = Missing | Detailed { title :: String, count :: Integer }
data Todo = Todo
  { name :: Label
  , identity :: Wrapped
  , decision :: Either String Integer
  , status :: Status
  , note :: Maybe (Maybe String)
  , budget :: Integer
  , choice :: Choice
  }
data Root = Root { todos :: [Box Todo], enabled :: Bool }
type RootAlias = Root
