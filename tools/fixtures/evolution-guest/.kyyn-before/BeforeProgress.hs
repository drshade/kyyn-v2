{-# LANGUAGE DeriveGeneric, DerivingStrategies, DeriveAnyClass #-}
module BeforeProgress where
import GHC.Generics (Generic)
import Agentic.Contract (Contract)
data State = State { completed :: Integer } deriving stock (Generic) deriving anyclass (Contract)
