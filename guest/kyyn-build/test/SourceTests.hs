-- GHC source inventory never typechecks unfinished function bodies.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless)
import Control.Exception (SomeException, try)
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcess)
import Kyyn.Build.Sources

main :: IO ()
main = do
  compiler <- readProcess "ghc" ["--print-libdir"] ""
  libdir <- case lines compiler of [path] -> pure path; _ -> fail "Missing compiler libdir"
  withSystemTempDirectory "kyyn-source-inventory" $ \directory -> do
    let after = directory </> "evolution.hs"
    writeFile after "module Evolution where\nimport Shared\nunfinished =\n"
    header <- moduleHeader libdir after
    unless (header == ("Evolution",["Shared"])) (fail ("Wrong partial module inventory: " ++ show header))
    let inputs = directory </> "inputs"
    createDirectory inputs
    writeFile (inputs </> "Hidden.lhs") "module Hidden where"
    rejects (sourceFiles inputs)
  putStrLn "Discovery reads headers without unfinished bodies and rejects unsupported source formats."
  where
    rejects action = do
      result <- try (action >> pure ()) :: IO (Either SomeException ())
      case result of Left _ -> pure (); Right _ -> fail "Invalid source inventory accepted"
