module Fixture.Config where
import Fixture.Types
import Kyyn.Validation
validate :: Config -> ValidationReport
validate (Config _ key) = ValidationReport [errorDiagnostic "fixture.config" "Empty secret key" | null key]
