{-# LANGUAGE OverloadedStrings #-}
module Evolution where
import qualified Kyyn.Workspace.Before.RecipeTypes.BeforeProgress.State
import qualified Kyyn.Workspace.After.RecipeTypes.After.Item
import qualified Kyyn.Workspace.After.RecipeFlows.AfterFlows
import qualified Before
import qualified After
import Kyyn.Workspace.Evolution
import Kyyn.Types.Fact (Fact(..))
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = evolve (Rationale "Add notes" []) (onFacts transform)
  where transform (Before.Root values) = Right (After.Root
          [Fact identity (After.Item amount "migrated") | Fact identity (Before.Item amount) <- values])
