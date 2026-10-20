{-# LANGUAGE ScopedTypeVariables #-}
module Kyyn.MicroHs.CompilerDiagnostic (compilerFailure, compilerMessage) where

import Control.Exception (ErrorCall, SomeException, displayException, fromException)
import Data.List (isPrefixOf, isInfixOf)
import MicroHs.Error (MhsError, formatMhsError)

-- | The source diagnostic of a failure the compiler reported about the program:
-- a located MhsError, or an ErrorCall from the compiler's internal checks.
-- Other exceptions are not compiler diagnostics.
compilerFailure :: SomeException -> Maybe String
compilerFailure err
  | Just (mhs :: MhsError) <- fromException err = Just (formatMhsError False mhs)
  | Just (_ :: ErrorCall) <- fromException err = Just (compilerMessage (displayException err))
  | otherwise = Nothing

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
