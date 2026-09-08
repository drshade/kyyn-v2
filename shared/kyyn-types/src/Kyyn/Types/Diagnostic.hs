module Kyyn.Types.Diagnostic
  ( Severity(..), DiagnosticLocation(..), Diagnostic(..), errorDiagnostic
  , ValidationReport(..), CheckResult(..), checkReport
  ) where

data Severity = Warning | Error deriving (Eq, Show)

data DiagnosticLocation
  = FactLocation String String (Maybe String)
  | SourceLocation String Integer Integer
  | ExampleLocation String
  deriving (Eq, Show)

data Diagnostic = Diagnostic
  { severity :: Severity
  , code :: String
  , message :: String
  , location :: Maybe DiagnosticLocation
  } deriving (Eq, Show)

errorDiagnostic :: String -> String -> Diagnostic
errorDiagnostic diagnosticCode diagnosticMessage =
  Diagnostic Error diagnosticCode diagnosticMessage Nothing

newtype ValidationReport = ValidationReport [Diagnostic] deriving (Eq, Show)

data CheckResult a = Rejected ValidationReport | Passed a ValidationReport
  deriving (Eq, Show)

checkReport :: a -> ValidationReport -> CheckResult a
checkReport value report@(ValidationReport diagnostics)
  | any isError diagnostics = Rejected report
  | otherwise = Passed value report
  where
    isError (Diagnostic level _ _ _) = level == Error
