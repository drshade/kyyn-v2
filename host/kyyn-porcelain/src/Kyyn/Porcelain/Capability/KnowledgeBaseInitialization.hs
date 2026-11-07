{-# LANGUAGE DataKinds, TypeFamilies, OverloadedStrings #-}
module Kyyn.Porcelain.Capability.KnowledgeBaseInitialization
  ( KnowledgeBaseInitialization(..), prepareKnowledgeBase, publishInitialRoot
  , initializeKnowledgeBase ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Path (DirectoryScope)
import Kyyn.Domain.Git (CommitMetadata)
import Kyyn.Domain.Publication (InitializationTarget, InitializationResult)
import Kyyn.Domain.Root (Root)
import Kyyn.Porcelain.Validated (Validated)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, openCapturedRoot)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution)
import Kyyn.Porcelain.Capability.RootStore (RootStore)
import Kyyn.Porcelain.Capability.Validation (checkRoot)

data KnowledgeBaseInitialization :: Effect where
  PrepareKnowledgeBase :: DirectoryScope -> KnowledgeBaseInitialization m (Either [Diagnostic] InitializationTarget)
  PublishInitialRoot :: InitializationTarget -> CommitMetadata -> Validated Root
    -> KnowledgeBaseInitialization m (Either [Diagnostic] InitializationResult)

type instance DispatchOf KnowledgeBaseInitialization = Dynamic

prepareKnowledgeBase :: KnowledgeBaseInitialization :> es => DirectoryScope -> Eff es (Either [Diagnostic] InitializationTarget)
prepareKnowledgeBase = send . PrepareKnowledgeBase

publishInitialRoot :: KnowledgeBaseInitialization :> es => InitializationTarget -> CommitMetadata -> Validated Root
  -> Eff es (Either [Diagnostic] InitializationResult)
publishInitialRoot target metadata = send . PublishInitialRoot target metadata

initializeKnowledgeBase :: (KnowledgeBaseInitialization :> es, RootOpening :> es, RootExecution :> es, RootStore :> es)
  => FileTree -> InitializationTarget -> CommitMetadata -> Eff es (CheckResult InitializationResult)
initializeKnowledgeBase template target metadata = do
  opened <- openCapturedRoot template
  case opened of
    Left diagnostics -> pure (Rejected (ValidationReport diagnostics))
    Right root -> do
      checked <- checkRoot root
      case checked of
        Rejected report -> pure (Rejected report)
        Passed validated report@(ValidationReport warnings) -> do
          published <- publishInitialRoot target metadata validated
          pure $ either (Rejected . ValidationReport . (warnings ++)) (`Passed` report) published
