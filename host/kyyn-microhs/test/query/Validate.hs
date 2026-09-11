module Validate (validate) where

import Schema (Root)
import Kyyn.Validation (ValidationReport(..))

validate :: Root -> ValidationReport
validate _ = ValidationReport []
