{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Domain.Diagnostic (module Kyyn.Types.Diagnostic, compilerContext, errorDiagnostic) where

import Kyyn.Types.Diagnostic hiding (errorDiagnostic)
import qualified Kyyn.Types.Diagnostic as Guest
import qualified Data.Text as Text

errorDiagnostic :: String -> String -> Diagnostic
errorDiagnostic code message = Guest.errorDiagnostic (Text.pack code) (Text.pack message)

-- Attribute a rejection to the operation preparing the code, not a guessed module role.
compilerContext :: String -> Diagnostic -> Diagnostic
compilerContext context diagnostic@(Diagnostic severity code message location)
  | code `elem` ["guest.compiler-rejected", "schema.compiler-rejected"] =
      Diagnostic severity (Text.pack (context ++ ".compiler-rejected")) message location
  | otherwise = diagnostic
