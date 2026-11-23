{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.FlowPreparation
  (FlowPreparation(..), PreparedFlow(..), PreparedFlowEntry(..), prepareInteractiveFlow) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledEntry (CompiledEntry)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.FlowClosure (FlowDeclaration)
import Kyyn.Domain.Model (ModelConfiguration)
import Kyyn.Domain.Recipe (RecipeDefinition)
import Kyyn.Types.Fact (Fact)
import Kyyn.Types.KnowledgeBase (RecipeId)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedPlugin)

-- All entries come from the same retained executable and selected source tree.
-- This is preparation only: it neither starts an instance nor performs actions.
data PreparedFlowEntry = PreparedFlowEntry
  { declaration :: FlowDeclaration, entry :: CompiledEntry
  , inputContract :: CheckedContract, outputContract :: CheckedContract
  , graph :: Value, mermaid :: Text }
data PreparedFlow = PreparedFlow
  { selected :: RecipeId, request :: Value, closure :: [PreparedFlowEntry]
  , plugins :: [PreparedPlugin], model :: Maybe ModelConfiguration }

data FlowPreparation :: Effect where
  PrepareInteractiveFlow :: FileTree -> [Fact RecipeDefinition] -> RecipeId -> Maybe Text
    -> FlowPreparation m (Either [Diagnostic] PreparedFlow)
type instance DispatchOf FlowPreparation = Dynamic

prepareInteractiveFlow :: FlowPreparation :> es
  => FileTree -> [Fact RecipeDefinition] -> RecipeId -> Maybe Text
  -> Eff es (Either [Diagnostic] PreparedFlow)
prepareInteractiveFlow code definitions ident = send . PrepareInteractiveFlow code definitions ident
