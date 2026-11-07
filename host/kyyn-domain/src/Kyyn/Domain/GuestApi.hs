{-# LANGUAGE DeriveAnyClass #-}
module Kyyn.Domain.GuestApi
  ( ApiModule, ApiSymbol, ModuleDescription(..), ExportDescription(..), ExportKind(..), WorkspaceCatalogue(..)
  , ApiSelection(..), ApiOrigin(..), ApiEntry(..) ) where

import Kyyn.Types.Guest (ModuleDescription(..), ExportDescription(..), ExportKind(..))
import Kyyn.Domain.Evolution (EvolutionWorkspace)
import Kyyn.Domain.Git (GitRevision)

data WorkspaceCatalogue = WorkspaceCatalogue
  { workspace :: EvolutionWorkspace, beforeRevision :: GitRevision, modules :: [ApiModule] }
  deriving (Eq, Show)

-- Discovery uses the compiler-owned protocol descriptions directly.
type ApiModule = ModuleDescription
type ApiSymbol = ExportDescription

data ApiSelection = ListApiModules | InspectApiModule String | InspectApiSymbol String
  deriving (Eq, Show)
data ApiOrigin = SdkOrigin | GeneratedOrigin | KbOrigin | PluginOrigin deriving (Eq, Show)
data ApiEntry = ApiEntry ApiOrigin ApiModule deriving (Eq, Show)
