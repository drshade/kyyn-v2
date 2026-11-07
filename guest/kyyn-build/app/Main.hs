module Main (main) where

import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Environment (getArgs)
import Kyyn.Build.Driver (buildGuest)

main :: IO ()
main = do
  -- Nix builders may use the C locale; authored and generated Haskell is UTF-8.
  setLocaleEncoding utf8
  arguments <- getArgs
  case arguments of
    [compiler,source,output] -> buildGuest compiler source output
    _ -> fail "Usage: kyyn-guest-build GHC SOURCE OUTPUT"
