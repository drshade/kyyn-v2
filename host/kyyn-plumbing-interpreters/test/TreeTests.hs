{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Control.Concurrent.Async (mapConcurrently)
import Data.List (nub)
import Data.Word (Word64)
import Numeric (showHex)
import Effectful (runEff)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Path
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.Failure
import System.Directory (createDirectory, createFileLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Random (mkStdGen, random, setStdGen, StdGen)

main :: IO ()
main = withSystemTempDirectory "kyyn-tree" $ \base -> do
  scope <- either fail pure (directoryScope base)
  let execute action = runEff (runFailure (runFileSystemIO scope action)) >>= either (fail . show) pure
      path = either error id . relativePath
  empty <- execute (FS.readTree scope)
  unless (null (files empty)) (fail "Empty directory capture")
  execute (FS.writeBytes scope (path "nested/value.dhall") "old")
  first <- execute (FS.readTree scope)
  execute (FS.writeBytes scope (path "nested/value.dhall") "new")
  second <- execute (FS.readTree scope)
  unless (files first == [(path "nested/value.dhall","old")] && files second == [(path "nested/value.dhall","new")])
    (fail "Capture did not retain explicit bytes")
  createDirectory (base </> "empty")
  withEmpty <- execute (FS.readTree scope)
  unless (withEmpty == second) (fail "Empty directories became stored files")
  createFileLink "nested/value.dhall" (base </> "link")
  rejected <- runEff (runFailure (runFileSystemIO scope (FS.readTree scope)))
  case rejected of Left _ -> pure (); Right _ -> fail "Symlink accepted"
  missing <- either fail pure (directoryScope (base </> "missing"))
  absent <- runEff (runFailure (runFileSystemIO scope (FS.readTree missing)))
  case absent of Left _ -> pure (); Right _ -> fail "Missing directory treated as empty"
  allocations <- either fail pure (directoryScope (base </> "allocations"))
  let seed = mkStdGen 42
      (firstNumber, _) = random seed :: (Word64, StdGen)
      collision = path (showHex firstNumber "")
  execute (FS.writeBytes allocations (path (relativeName collision ++ "/retained")) "old archive")
  setStdGen seed
  allocated <- execute (FS.createUniqueDirectory allocations)
  unless (allocated /= collision) (fail "Allocation reused an existing directory")
  retained <- execute (FS.readBytes allocations (path (relativeName collision ++ "/retained")))
  unless (retained == "old archive") (fail "Allocation overwrote existing files")
  concurrent <- mapConcurrently (\_ -> execute (FS.createUniqueDirectory allocations)) [1..20 :: Int]
  unless (length (nub (allocated : concurrent)) == 21 && all (all (`elem` ("0123456789abcdef" :: String)) . relativeName) concurrent)
    (fail "Concurrent allocations did not return distinct hexadecimal names")
  forM_ concurrent $ \name -> do
    child <- either fail pure (directoryScope (scopedPath allocations name))
    snapshot <- execute (FS.readTree child)
    unless (null (files snapshot)) (fail "Allocated directory not empty")
  badParent <- either fail pure (directoryScope (base </> "nested/value.dhall"))
  failedAllocation <- runEff (runFailure (runFileSystemIO scope (FS.createUniqueDirectory badParent)))
  case failedAllocation of Left _ -> pure (); Right _ -> fail "File was accepted as allocation parent"
  putStrLn "Directory byte-tree capture, empty trees and read failures passed."
