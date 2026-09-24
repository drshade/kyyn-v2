module Kyyn.Domain.Diagnostic (module Kyyn.Types.Diagnostic, compilerContext) where

import Kyyn.Types.Diagnostic

-- Attribute a rejection to the operation preparing the code, not a guessed module role.
compilerContext :: String -> Diagnostic -> Diagnostic
compilerContext context diagnostic@(Diagnostic severity code message location)
  | code `elem` ["guest.compiler-rejected", "schema.compiler-rejected"] =
      Diagnostic severity (context ++ ".compiler-rejected") message location
  | otherwise = diagnostic
