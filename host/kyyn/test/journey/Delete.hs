{-# LANGUAGE OverloadedStrings #-}
module Evolution where

import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified TodoSchemaV2 as Schema
import qualified Kyyn.Workspace.Target as AfterCollections

evolution :: Evolution Schema.Root
evolution = prepare (pure ()) $
  edit (Rationale "Retire the completed report." [])
    (within AfterCollections.todos $ remove (FactId "todo-001"))
