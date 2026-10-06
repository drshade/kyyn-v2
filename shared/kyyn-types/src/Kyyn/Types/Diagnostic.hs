{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.Diagnostic
  ( Severity(..), DiagnosticLocation(..), Diagnostic(..), errorDiagnostic
  , ValidationReport(..), CheckResult(..), checkReport
  ) where

import Data.Text (Text)

-- | Warnings permit a check to pass; errors reject it.
data Severity = Warning | Error deriving (Eq, Show)

-- | Locate a problem in a fact (collection, ID, optional field), source (file, line, column), or named example.
data DiagnosticLocation
  = FactLocation Text Text (Maybe Text)
  | SourceLocation Text Integer Integer
  | ExampleLocation Text
  deriving (Eq, Show)

-- | A severity, machine-readable code, explanatory message and optional location.
data Diagnostic = Diagnostic
  { severity :: Severity
  , code :: Text
  , message :: Text
  , location :: Maybe DiagnosticLocation
  } deriving (Eq, Show)

-- | Create an error from a code and message, without a specific location.
errorDiagnostic :: Text -> Text -> Diagnostic
errorDiagnostic diagnosticCode diagnosticMessage =
  Diagnostic Error diagnosticCode diagnosticMessage Nothing

-- | Diagnostics returned by validation. An empty list represents no reported problems.
newtype ValidationReport = ValidationReport [Diagnostic] deriving (Eq, Show)

-- | A rejected report or a successful value accompanied by its report.
data CheckResult a = Rejected ValidationReport | Passed a ValidationReport
  deriving (Eq, Show)

-- | Reject a value if the report contains any errors; otherwise pass it with the report.
checkReport :: a -> ValidationReport -> CheckResult a
checkReport value report@(ValidationReport diagnostics)
  | any isError diagnostics = Rejected report
  | otherwise = Passed value report
  where
    isError (Diagnostic level _ _ _) = level == Error
