module Kyyn.MicroHs.CompilerDiagnostic (compilerMessage) where

import Data.List (isPrefixOf, isInfixOf)

-- Compiler ErrorCall rendering appends GHC stack frames to the source diagnostic.
compilerMessage :: String -> String
compilerMessage = unlines . clean . lines
  where
    clean [] = []
    clean (line:rest)
      | line == "CallStack (from HasCallStack):" || line == "HasCallStack backtrace:" =
          clean (dropWhile frame rest)
      | otherwise = line : clean rest
    frame line = "  " `isPrefixOf` line && ", called at " `isInfixOf` line
