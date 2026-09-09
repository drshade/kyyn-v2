module Validate (validate) where

import Schema (Root)
import Kyyn.Types.Diagnostic (ValidationReport(..))

validate :: Root -> ValidationReport
validate _ = ValidationReport []
