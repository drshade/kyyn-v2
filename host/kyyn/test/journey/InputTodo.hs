{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies #-}
module Input.Todo where
import GHC.Generics (Generic)
import Data.Text (Text)
import Kyyn.Contract (Contract)
data Status = Open | InProgress | Done deriving stock Generic deriving anyclass Contract
data Todo = Todo { title :: Text, status :: Status } deriving stock Generic deriving anyclass Contract
