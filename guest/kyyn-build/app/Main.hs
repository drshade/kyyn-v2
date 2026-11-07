module Main (main) where

import Control.Exception (IOException, catch, displayException)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Environment (getArgs)
import Kyyn.Build.Driver (buildGuest)

main :: IO ()
main = run `catch` report
  where
    report :: IOException -> IO ()
    report failure = hPutStrLn stderr (displayException failure) >> exitFailure

run :: IO ()
run = do
  -- Nix builders may use the C locale; authored and generated Haskell is UTF-8.
  setLocaleEncoding utf8
  arguments <- getArgs
  case arguments of
    [compiler,source,output] -> buildGuest compiler source output
    _ -> fail "Usage: kyyn-guest-build GHC SOURCE OUTPUT"
