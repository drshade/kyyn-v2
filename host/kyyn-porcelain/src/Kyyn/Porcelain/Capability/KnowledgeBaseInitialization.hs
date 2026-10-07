{-# LANGUAGE DataKinds, TypeFamilies, OverloadedStrings #-}
module Kyyn.Porcelain.Capability.KnowledgeBaseInitialization
  ( KnowledgeBaseInitialization(..), prepareKnowledgeBase, publishInitialRoot
  , initializeKnowledgeBase, initialRootFiles ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.Path (DirectoryScope, relativePath, relativeName)
import Kyyn.Domain.Git (CommitMetadata)
import Kyyn.Domain.Publication (InitializationTarget, InitializationResult)
import Kyyn.Domain.Root (Root, factsLocation)
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
  => InitializationTarget -> CommitMetadata -> Eff es (CheckResult InitializationResult)
initializeKnowledgeBase target metadata = do
  opened <- either (pure . Left . pure . errorDiagnostic "kb.scaffold") openCapturedRoot initialRootFiles
  case opened of
    Left diagnostics -> pure (Rejected (ValidationReport diagnostics))
    Right root -> do
      checked <- checkRoot root
      case checked of
        Rejected report -> pure (Rejected report)
        Passed validated report@(ValidationReport warnings) -> do
          published <- publishInitialRoot target metadata validated
          pure $ either (Rejected . ValidationReport . (warnings ++)) (`Passed` report) published

initialRootFiles :: Either String FileTree
initialRootFiles = traverse (\(name,bytes) -> (,) <$> relativePath name <*> pure bytes)
  [ ("kb.dhall", "{ schemaType = \"RootV1.Root\", schemaMetadata = \"RootV1.metadata\", validator = \"Validate.validate\", queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }\n")
  , ("src/RootV1.hs", "module RootV1 where\n\nimport Kyyn.Schema\n\ndata Root = Root deriving (Eq, Show)\n\nmetadata :: SchemaMetadata\nmetadata = SchemaMetadata [] [] []\n")
  , ("src/Validate.hs", "module Validate where\n\nimport qualified RootV1 as Schema\nimport Kyyn.Validation\n\nvalidate :: Schema.Root -> ValidationReport\nvalidate _ = ValidationReport []\n")
  , (relativeName factsLocation ++ "/root.dhall", "{=}\n")
  , ("recipes.dhall", "[] : List { id : Text, value : < OpenAgent : { instructions : Text, stateType : Text } | ClosedAgent : { flow : Text } > }\n")
  ] >>= fileTree
