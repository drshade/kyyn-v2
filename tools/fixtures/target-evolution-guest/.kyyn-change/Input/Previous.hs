module Input.Previous where
import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
data Item = Item { amount :: Integer } deriving stock (Generic) deriving anyclass (Contract)
data State = State { count :: Integer } deriving stock (Generic) deriving anyclass (Contract)
