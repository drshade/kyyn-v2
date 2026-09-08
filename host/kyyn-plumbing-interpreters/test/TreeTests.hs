{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless)
import Effectful (runEff)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Path
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.Failure
import System.Directory (createDirectory, createFileLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

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
  putStrLn "Directory byte-tree capture, empty trees and read failures passed."
