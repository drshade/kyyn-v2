{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RecipeStore
  ( RecipeStore(..), loadRecipesAt, loadCurationAt ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Curation (CurationRegister)
import Kyyn.Domain.Recipe (RecipeDefinition)
import Kyyn.Types.Fact (Fact)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)

data RecipeStore :: Effect where
  LoadRecipesAt :: KnowledgeBase -> GitRevision -> RecipeStore m (Either [Diagnostic] [Fact RecipeDefinition])
  LoadCurationAt :: KnowledgeBase -> GitRevision -> RecipeStore m (Either [Diagnostic] CurationRegister)

type instance DispatchOf RecipeStore = Dynamic

loadRecipesAt :: RecipeStore :> es => KnowledgeBase -> GitRevision -> Eff es (Either [Diagnostic] [Fact RecipeDefinition])
loadRecipesAt kb = send . LoadRecipesAt kb

loadCurationAt :: RecipeStore :> es => KnowledgeBase -> GitRevision -> Eff es (Either [Diagnostic] CurationRegister)
loadCurationAt kb = send . LoadCurationAt kb
