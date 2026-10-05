{-# LANGUAGE DeriveAnyClass #-}
module Kyyn.Domain.GuestApi
  ( ApiModule(..), ApiSymbol(..), Namespace(..), WorkspaceCatalogue(..)
  , ApiSelection(..), ApiOrigin(..), ApiEntry(..) ) where

import Control.DeepSeq (NFData)
import GHC.Generics (Generic)
import Kyyn.Domain.Evolution (EvolutionWorkspace)
import Kyyn.Domain.Git (GitRevision)

data WorkspaceCatalogue = WorkspaceCatalogue
  { workspace :: EvolutionWorkspace, beforeRevision :: GitRevision, modules :: [ApiModule] }
  deriving (Eq, Show)

data ApiModule = ApiModule String [ApiSymbol]
  deriving (Eq, Show, Generic, NFData)

data ApiSelection = ListApiModules | InspectApiModule String | InspectApiSymbol String
  deriving (Eq, Show)
data ApiOrigin = SdkOrigin | GeneratedOrigin | KbOrigin deriving (Eq, Show)
data ApiEntry = ApiEntry ApiOrigin ApiModule deriving (Eq, Show)

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
