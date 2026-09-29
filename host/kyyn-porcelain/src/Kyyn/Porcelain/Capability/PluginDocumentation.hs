{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginDocumentation
  ( PluginDocumentation(..), PluginLocation(..), listPlugins, describePlugin, readPluginGuide ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionWorkspace)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Plugin

data PluginLocation
  = AcceptedPlugins KnowledgeBase GitRevision
  | EvolutionPlugins EvolutionWorkspace
  deriving (Eq, Show)

data PluginDocumentation :: Effect where
  ListPlugins :: PluginLocation -> PluginDocumentation m (Either [Diagnostic] [PluginName])
  DescribePlugin :: PluginLocation -> PluginName -> PluginDocumentation m (Either [Diagnostic] PluginDescription)
  ReadPluginGuide :: PluginLocation -> PluginName -> PluginDocumentation m (Either [Diagnostic] PluginGuide)

type instance DispatchOf PluginDocumentation = Dynamic

listPlugins :: PluginDocumentation :> es => PluginLocation -> Eff es (Either [Diagnostic] [PluginName])
listPlugins = send . ListPlugins

describePlugin :: PluginDocumentation :> es => PluginLocation -> PluginName -> Eff es (Either [Diagnostic] PluginDescription)
describePlugin location = send . DescribePlugin location

readPluginGuide :: PluginDocumentation :> es => PluginLocation -> PluginName -> Eff es (Either [Diagnostic] PluginGuide)
readPluginGuide location = send . ReadPluginGuide location
