{-# LANGUAGE GADTs, DeriveGeneric #-}
module Kyyn.Types.LiveQuery (LiveQueryCall(..), LiveQueryBinding(..)) where

import Agentic.Value (Value)
import Data.Text (Text)
import Data.Aeson (ToJSON, FromJSON)
import GHC.Generics (Generic)
import Kyyn.Types.Contract (Description)
import Kyyn.Types.Plugin (FetchError)

data LiveQueryBinding = LiveQueryBinding Text Text Text Text
  deriving (Eq, Show, Generic)
instance ToJSON LiveQueryBinding
instance FromJSON LiveQueryBinding

data LiveQueryCall a where
  InvokeLiveQuery :: LiveQueryBinding -> Description -> Description -> Value
    -> LiveQueryCall (Either FetchError Value)
