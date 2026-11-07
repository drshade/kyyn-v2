-- GHC header inventory and evolution source collision rules, independent of
-- import search order. No compiler is run on an unfinished function body.
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
  withSystemTempDirectory "kyyn-source-merge" $ \directory -> do
    let before = directory </> "before.hs"
        after = directory </> "after.hs"
        common = "module Shared (value) where\nimport qualified Data.List as List\nvalue = List.sort [1 :: Integer]\n"
    writeFile before common
    writeFile after common
    merged <- mergeSources libdir (directory </> "merged") [before,after]
    unless (length merged == 1 && map snd merged == [before]) (fail "Identical shared module was not deduplicated")
    writeFile after "module Shared where\nvalue = False\n"
    rejects (mergeSources libdir (directory </> "conflict") [before,after])
    writeFile after "module Evolution where\nimport Shared\nunfinished =\n"
    header <- moduleHeader libdir after
    unless (header == ("Evolution",["Shared"])) (fail ("Wrong partial module inventory: " ++ show header))
    let inputs = directory </> "inputs"
    createDirectory inputs
    writeFile (inputs </> "Hidden.lhs") "module Hidden where"
    rejects (sourceFiles inputs)
  putStrLn "Shared modules deduplicate, changed definitions collide, and discovery reads headers without unfinished bodies."
  where
    rejects action = do
      result <- try (action >> pure ()) :: IO (Either SomeException ())
      case result of Left _ -> pure (); Right _ -> fail "Invalid source inventory accepted"
