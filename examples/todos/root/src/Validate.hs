module Validate where

import qualified TodoSchemaV1 as Schema
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.Diagnostic

validate :: Schema.Root -> ValidationReport
validate (Schema.Root facts) = ValidationReport
  [ Diagnostic Error "todo.blank-title" "A todo needs a title."
      (Just (FactLocation "todos" identity (Just "title")))
  | Fact (FactId identity) (Schema.Todo title _) <- facts, null title
  ]
