{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.WorkspaceApi (runWorkspaceApi) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.GuestApi (WorkspaceCatalogue(..))
import Kyyn.Domain.Root (SourceRoot(..), RootDefinition(..))
import Kyyn.Plumbing.Capability.ApiInspection (ApiInspection, inspectApiModules)
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, mergeEvolutionSources)
import Kyyn.Porcelain.Capability.EvolutionPreparation (prepareEvolution)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation, prepareToolBindings)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePlugins)
import Kyyn.Porcelain.Capability.WorkspaceApi (WorkspaceApi(..))

runWorkspaceApi :: (EvolutionStore :> es, RootOpening :> es, ApiInspection :> es, ToolPreparation :> es, PluginPreparation :> es)
  => FileTree -> Eff (WorkspaceApi : es) a -> Eff es a
runWorkspaceApi sdk = interpret $ \_ operation -> case operation of
  InspectToolApi code -> runExceptT $ do
    plugins <- ExceptT (preparePlugins code)
    (sources,names) <- ExceptT (prepareToolBindings code plugins)
    ExceptT (inspectApiModules sources names)
  InspectWorkspaceApi workspace -> runExceptT $ do
    PreparedEvolution (EvolutionContext _ _ (Before revision _) _)
      (SourceRoot before _ (RootDefinition _ _ _ _ _ beforeSources) closure)
      (SourceRoot after _ (RootDefinition _ _ _ _ _ afterSources) afterClosure) <- ExceptT (prepareEvolution workspace)
    old <- checked (fileTree [(p,b) | (p,b) <- files beforeSources, p `elem` closure])
    new <- checked (fileTree [(p,b) | (p,b) <- files afterSources, p `elem` afterClosure])
    bindings <- checked (evolutionBindings before after)
    sources <- checked (mergeEvolutionSources [old,new,sdk,bindings])
    modules <- ExceptT (inspectApiModules sources
      ["Kyyn.Workspace.Evolution", "Kyyn.Workspace.Before", "Kyyn.Workspace.After"])
    pure (WorkspaceCatalogue workspace revision modules)
  
checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "guest.workspace-sources") pure
