module Validate where

import qualified Schema
import Kyyn.Validation

validate :: Schema.Root -> ValidationReport
validate _ = ValidationReport []
