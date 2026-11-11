-- Native plugin contract, retry and data checks using the actual guest language defaults.
-- Run from the repository root with cabal exec -- runghc -package=kyyn-guest-build.
-- Provider responses are recorded; acquisition integration uses real guest tests.
module Main where

import Control.Monad (forM_)
import Kyyn.Build.Inspection (packageOptions)
import Kyyn.Build.Language (guestLanguageFlags)
import System.Process (callProcess, readProcess)

main :: IO ()
main = do
  libdir <- takeWhile (/= '\n') <$> readProcess "ghc" ["--print-libdir"] ""
  packages <- packageOptions libdir
  forM_ ["PluginContractTests.hs", "GraphRetryTests.hs", "PluginDataTests.hs"] $ \test ->
    callProcess "runghc" (map ("--ghc-arg=" ++) (guestLanguageFlags ++ packages ++
      [ "-Wall", "-Werror"
      , "-iplugins/local-file/src", "-iplugins/github/src"
      , "-iplugins/microsoft-graph/src", "-iplugins/salesforce/src"
      ]) ++ ["guest/kyyn-sdk/test/" ++ test])
