module Schema (Root(..), Item(..)) where
import Data.Text (Text)
import GHC.Generics (Generic)
import Kyyn.Schema (Contract, Fact)
data Root = Root { items :: [Fact Item], total :: Integer }
  deriving stock (Generic) deriving anyclass (Contract)
data Item = Item { amount :: Integer, note :: Text }
  deriving stock (Generic) deriving anyclass (Contract)
