module Main (main) where

import System.Environment (getArgs)
import Kyyn.Build.Driver (buildGuest)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [compiler,source,output] -> buildGuest compiler source output
    _ -> fail "Usage: kyyn-guest-build GHC SOURCE OUTPUT"
