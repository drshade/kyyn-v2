{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies #-}
module Fixture.Types where
import GHC.Generics (Generic)
import Kyyn.Schema (Contract)
import Data.Text (Text)
data Config = Config { endpoint :: Text, secretKey :: Text, localPath :: Text } deriving stock Generic deriving anyclass Contract
type Payload = Text
