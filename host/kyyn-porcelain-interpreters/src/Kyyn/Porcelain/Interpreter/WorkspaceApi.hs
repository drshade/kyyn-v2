{-# LANGUAGE GADTs, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Porcelain.Interpreter.WorkspaceApi (runWorkspaceApi) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Guest (checkedModules)
import Kyyn.Domain.GuestApi (WorkspaceCatalogue(..), ModuleDescription(..), ApiEntry(..), ApiOrigin(..), ApiSelection(..))
import Kyyn.Plumbing.Capability.Git (Git)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection, describeGuest)
import Kyyn.Porcelain.Protocol.EvolutionPreparation (prepareEvolutionDescription, prepareEvolutionApi)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore)
import Kyyn.Porcelain.Capability.RootStore (RootStore)
import Kyyn.Porcelain.Capability.WorkspaceApi (WorkspaceApi(..))

runWorkspaceApi :: (EvolutionStore :> es, RootStore :> es, Git :> es, GuestCompilation :> es, GuestInspection :> es)
  => Eff (WorkspaceApi : es) a -> Eff es a
runWorkspaceApi = interpret $ \_ operation -> case operation of
  InspectRootApi code selection -> runExceptT $ do
    let selected = case selection of
          ListApiModules -> Nothing
          InspectApiModule name -> Just (Text.pack name)
          InspectApiSymbol name -> Just (Text.pack name)
    source <- either (throwE . pure . errorDiagnostic "guest.workspace-sources") pure
      (guestSources (DiscoveryEntries (RootApi selected)) (files code))
    program <- ExceptT (compileGuest source)
    described <- ExceptT (describeGuest program)
    pure [ApiEntry (origin entry.moduleSource) entry | entry <- checkedModules described]
  InspectWorkspaceApi workspace selection -> runExceptT $ case selection of
    ListApiModules -> do
      (PreparedEvolution (EvolutionContext _ _ (Before revision _) _) _ _ _,described) <-
        ExceptT (prepareEvolutionDescription workspace)
      pure (WorkspaceCatalogue workspace revision (filter public (checkedModules described)))
    _ -> do
      let selected = case selection of InspectApiModule name -> name; InspectApiSymbol name -> name
      (revision,described) <- ExceptT (prepareEvolutionApi workspace [Text.pack selected])
      pure (WorkspaceCatalogue workspace revision (checkedModules described))
  where
    origin path
      | Text.null path = SdkOrigin
      | ".kyyn-generated/" `Text.isPrefixOf` path = GeneratedOrigin
      | "plugins/" `Text.isPrefixOf` path = PluginOrigin
      | otherwise = KbOrigin
    public entry = "Kyyn.Workspace." `Text.isPrefixOf` entry.moduleName || entry.moduleName == "KyynFrozenProposal"
