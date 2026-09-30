{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginDiscovery
  ( PluginDiscovery(..), listTaps, addTap, removeTap, updateTaps, searchPlugins, resolvePlugin, readAvailableGuide ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Plugin (PluginName, PluginGuide)
import Kyyn.Domain.Tap

data PluginDiscovery :: Effect where
  ListTaps :: KnowledgeBase -> PluginDiscovery m (Either [Diagnostic] [(Tap, Maybe GitRevision)])
  AddTap :: KnowledgeBase -> Tap -> PluginDiscovery m (Either [Diagnostic] ())
  RemoveTap :: KnowledgeBase -> TapName -> PluginDiscovery m (Either [Diagnostic] ())
  UpdateTaps :: KnowledgeBase -> Maybe TapName -> PluginDiscovery m (Either [Diagnostic] [(Tap,GitRevision)])
  SearchPlugins :: KnowledgeBase -> String -> PluginDiscovery m (Either [Diagnostic] [AvailablePlugin])
  ResolvePlugin :: KnowledgeBase -> TapName -> PluginName -> PluginDiscovery m (Either [Diagnostic] AvailablePlugin)
  ReadAvailableGuide :: KnowledgeBase -> TapName -> PluginName -> PluginDiscovery m (Either [Diagnostic] PluginGuide)

type instance DispatchOf PluginDiscovery = Dynamic

listTaps :: PluginDiscovery :> es => KnowledgeBase -> Eff es (Either [Diagnostic] [(Tap, Maybe GitRevision)])
listTaps = send . ListTaps
addTap :: PluginDiscovery :> es => KnowledgeBase -> Tap -> Eff es (Either [Diagnostic] ())
addTap kb = send . AddTap kb
removeTap :: PluginDiscovery :> es => KnowledgeBase -> TapName -> Eff es (Either [Diagnostic] ())
removeTap kb = send . RemoveTap kb
updateTaps :: PluginDiscovery :> es => KnowledgeBase -> Maybe TapName -> Eff es (Either [Diagnostic] [(Tap,GitRevision)])
updateTaps kb = send . UpdateTaps kb
searchPlugins :: PluginDiscovery :> es => KnowledgeBase -> String -> Eff es (Either [Diagnostic] [AvailablePlugin])
searchPlugins kb = send . SearchPlugins kb
resolvePlugin :: PluginDiscovery :> es => KnowledgeBase -> TapName -> PluginName -> Eff es (Either [Diagnostic] AvailablePlugin)
resolvePlugin kb tap = send . ResolvePlugin kb tap
readAvailableGuide :: PluginDiscovery :> es => KnowledgeBase -> TapName -> PluginName -> Eff es (Either [Diagnostic] PluginGuide)
readAvailableGuide kb tap = send . ReadAvailableGuide kb tap
