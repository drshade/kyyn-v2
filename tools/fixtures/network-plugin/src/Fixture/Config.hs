{-# LANGUAGE OverloadedStrings #-}
module Fixture.Config where
import qualified Data.Text as Text
import Fixture.Types
import Kyyn.Validation
validate :: Config -> ValidationReport
validate (Config _ key _) = ValidationReport [errorDiagnostic "fixture.config" "Empty secret key" | Text.null key]
