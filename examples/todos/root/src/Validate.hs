module Validate where

import qualified TodoSchemaV1 as Schema
import Kyyn.Schema (Fact(..), FactId(..))
import Kyyn.Validation

validate :: Schema.Root -> ValidationReport
validate (Schema.Root facts) = ValidationReport
  [ Diagnostic Error "todo.blank-title" "A todo needs a title."
      (Just (FactLocation "todos" identity (Just "title")))
  | Fact (FactId identity) (Schema.Todo title _) <- facts, null title
  ]
