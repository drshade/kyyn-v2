{-# LANGUAGE OverloadedStrings #-}
module Validate where

import qualified RootV1 as Schema
import Kyyn.Validation

validate :: Schema.Root -> ValidationReport
validate _ = ValidationReport []
