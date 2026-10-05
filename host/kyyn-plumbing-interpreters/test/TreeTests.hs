-- Real file-tree capture/replacement and scoped directory reservation: collisions,
-- concurrency, absence versus failure, symlink/file refusals and cleanup.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Control.Concurrent.Async (mapConcurrently)
import Data.List (nub, isPrefixOf)
import qualified Data.ByteString as Bytes
import Data.Word (Word64)
import Numeric (showHex)
import Effectful (runEff)
import Kyyn.Domain.FileTree (files, fileTree)
import Kyyn.Domain.Path
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.Failure
import System.Directory (createDirectory, createFileLink, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Random (mkStdGen, random, setStdGen, StdGen)

main :: IO ()
main = withSystemTempDirectory "kyyn-tree" $ \base -> do
  scope <- either fail pure (directoryScope base)
  let execute action = runEff (runFailure (runFileSystemIO scope action)) >>= either (fail . show) pure
      path = either error id . relativePath
  empty <- execute (FS.readTree scope)
  initialNames <- execute (FS.listDirectory scope)
  unless (initialNames == Just []) (fail "Empty directory listing was not present")
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
  absentNames <- execute (FS.listDirectory missing)
  unless (absentNames == Nothing) (fail "Absent directory listing was not missing")
  names <- execute (FS.listDirectory scope)
  unless (names == Just [path "empty",path "link",path "nested"]) (fail "Directory listing descended, lost entries or changed order")
  createFileLink "absent-target" (base </> "dangling")
  Bytes.writeFile (base </> "unrelated:entry") "preserved"
  forM_ ["empty", "nested/value.dhall", "link", "dangling"] $ \name -> do
    present <- execute (FS.entryExists scope (path name))
    unless present (fail "Existing entry was treated as absent")
  absentEntry <- execute (FS.entryExists scope (path ".git"))
  unless (not absentEntry) (fail "Missing entry was treated as present")
  absent <- runEff (runFailure (runFileSystemIO scope (FS.readTree missing)))
  case absent of Left _ -> pure (); Right _ -> fail "Missing directory treated as empty"
  allocations <- either fail pure (directoryScope (base </> "allocations"))
  named <- either fail pure (directoryScope (base </> "reserved"))
  reservations <- mapConcurrently (\_ -> execute (FS.createDirectory named)) [1..20 :: Int]
  unless (length (filter id reservations) == 1) (fail "Exclusive directory reservation did not have exactly one winner")
  execute (FS.writeBytes named (path "retained") "preserved")
  reservedAgain <- execute (FS.createDirectory named)
  reservedContents <- execute (FS.readBytes named (path "retained"))
  unless (not reservedAgain && reservedContents == "preserved") (fail "Named creation reused or modified an existing directory")
  namedFile <- either fail pure (directoryScope (base </> "nested/value.dhall"))
  occupied <- execute (FS.createDirectory namedFile)
  unless (not occupied) (fail "Named creation accepted an existing file")
  missingParent <- either fail pure (directoryScope (base </> "missing-parent/child"))
  failedNamed <- runEff (runFailure (runFileSystemIO scope (FS.createDirectory missingParent)))
  case failedNamed of Left _ -> pure (); Right _ -> fail "Exclusive creation silently created its parent"
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
  badListing <- runEff (runFailure (runFileSystemIO scope (FS.listDirectory badParent)))
  case badListing of Left _ -> pure (); Right _ -> fail "Listing a file became empty/absent directory"
  failedAllocation <- runEff (runFailure (runFileSystemIO scope (FS.createUniqueDirectory badParent)))
  case failedAllocation of Left _ -> pure (); Right _ -> fail "File was accepted as allocation parent"
  missingBytes <- execute (FS.readOptionalBytes scope (path "absent/file"))
  unless (missingBytes == Nothing) (fail "Absent file was not optional")
  let target = path "pointer/latest"
      completeA = Bytes.replicate 131072 65
      completeB = Bytes.replicate 131072 66
  execute (FS.replaceBytes scope target completeA)
  firstPointer <- execute (FS.readOptionalBytes scope target)
  unless (firstPointer == Just completeA) (fail "Replacement did not create complete file")
  observed <- mapConcurrently (\n -> do
    execute (FS.replaceBytes scope target (if even n then completeA else completeB))
    execute (FS.readBytes scope target)) [1..20 :: Int]
  unless (all (`elem` [completeA,completeB]) observed) (fail "Concurrent replacement exposed partial bytes")
  leftovers <- listDirectory (base </> "pointer")
  unless (leftovers == ["latest"]) (fail "Replacement leaked temporary files")
  badRead <- runEff (runFailure (runFileSystemIO scope (FS.readOptionalBytes scope (path "pointer"))))
  case badRead of Left _ -> pure (); Right _ -> fail "Directory read failure became absence"
  badReplace <- runEff (runFailure (runFileSystemIO scope (FS.replaceBytes scope (path "pointer") "bad")))
  case badReplace of Left _ -> pure (); Right _ -> fail "Directory replacement succeeded"
  retainedPointer <- execute (FS.readBytes scope target)
  unless (retainedPointer `elem` [completeA,completeB]) (fail "Failed replacement damaged existing directory")
  let tree entries = either error id (fileTree [(path name, bytes) | (name,bytes) <- entries])
  execute (FS.replaceTree scope scope (path "package") (tree [("old", "obsolete"),("keep", "before")]))
  execute (FS.replaceTree scope scope (path "package") (tree [("keep", "after"),("nested/new", "new")]))
  packageScope <- either fail pure (directoryScope (base </> "package"))
  replaced <- execute (FS.readTree packageScope)
  unless (replaced == tree [("keep", "after"),("nested/new", "new")]) (fail "Tree replacement retained obsolete files")
  stagedFailure <- runEff (runFailure (runFileSystemIO scope
    (FS.replaceTree scope scope (path "package") (tree [(replicate 300 'x', "too long")]))))
  case stagedFailure of Left _ -> pure (); Right _ -> fail "Oversized filename unexpectedly staged"
  afterFailure <- execute (FS.readTree packageScope)
  unless (afterFailure == replaced) (fail "Staging failure damaged old tree")
  forM_ ["link", "dangling", "nested/value.dhall"] $ \name -> do
    refused <- runEff (runFailure (runFileSystemIO scope (FS.replaceTree scope scope (path name) replaced)))
    case refused of Left _ -> pure (); Right _ -> fail "Tree replacement accepted file or symlink"
  finalNames <- listDirectory base
  unless (all (not . (".kyyn-replace-" `isPrefixOf`)) finalNames) (fail "Staging failure leaked temporary tree")
  putStrLn "Directory byte-tree capture, empty trees and read failures passed."
