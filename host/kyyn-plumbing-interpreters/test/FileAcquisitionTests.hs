-- Native text/fingerprint capture: stable reads, changed paths/contents and invalid
-- UTF-8 refusal. No guest compiler.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless)
import qualified Data.ByteString as Bytes
import Effectful (runEff)
import Kyyn.Domain.Path (directoryScope, relativePath)
import Kyyn.Plumbing.Capability.FileAcquisition
import Kyyn.Plumbing.Interpreter.FileAcquisition (runFileAcquisitionIO)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = withSystemTempDirectory "kyyn-file-acquisition-" $ \directory -> do
  let scope = either error id (directoryScope directory)
      path = either error id (relativePath "source.txt")
      capture = runEff (runFileAcquisitionIO (readSourceText scope path))
      write = Bytes.writeFile (directory </> "source.txt")
  write "abc"
  first <- capture
  repeated <- capture
  unless (repeated == first) (fail "Stable file capture changed")
  case first of
    Right (CapturedText "abc" (EvidenceFingerprint token))
      | length token == 64 && all (`elem` ("0123456789abcdef" :: String)) token -> pure ()
    _ -> fail "Expected captured content and lowercase SHA-256 fingerprint"
  Bytes.writeFile (directory </> "other.txt") "abc"
  moved <- runEff (runFileAcquisitionIO (readSourceText scope (either error id (relativePath "other.txt"))))
  unless (moved /= first) (fail "Changed path did not change fingerprint")
  write "abcd"
  changed <- capture
  case changed of
    Right (CapturedText "abcd" token) | first /= Right (CapturedText "abc" token) -> pure ()
    _ -> fail "Changed bytes did not change captured text and fingerprint"
  write (Bytes.pack [255,254])
  invalid <- capture
  case invalid of
    Left _ -> pure ()
    Right _ -> fail "Invalid UTF-8 was captured as text"
  putStrLn "File acquisition: content/fingerprint capture, stable SHA-256, changes and invalid UTF-8 passed."
