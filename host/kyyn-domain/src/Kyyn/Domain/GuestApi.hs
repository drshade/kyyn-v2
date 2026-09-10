{-# LANGUAGE DeriveAnyClass #-}
module Kyyn.Domain.GuestApi
  ( ApiModule(..), ApiSymbol(..), Namespace(..) ) where

import Control.DeepSeq (NFData)
import GHC.Generics (Generic)

data ApiModule = ApiModule String [ApiSymbol]
  deriving (Eq, Show, Generic, NFData)

data Namespace = TypeNamespace | ValueNamespace
  deriving (Eq, Ord, Show, Generic, NFData)

data ApiSymbol = ApiSymbol
  { name :: String
  , namespace :: Namespace
  , definedAs :: String
  , checkedSignature :: String
  , declaration :: Maybe String
  , documentation :: Maybe String
  } deriving (Eq, Show, Generic, NFData)
