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
      expected = CapturedText "abc" (EvidenceFingerprint
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  write "abc"
  first <- capture
  repeated <- capture
  unless (first == Right expected && repeated == first) (fail "Stable content capture or SHA-256 vector failed")
  write "abcd"
  changed <- capture
  case changed of
    Right (CapturedText "abcd" token) | token /= EvidenceFingerprint
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" -> pure ()
    _ -> fail "Changed bytes did not change captured text and fingerprint"
  write (Bytes.pack [255,254])
  invalid <- capture
  case invalid of
    Left _ -> pure ()
    Right _ -> fail "Invalid UTF-8 was captured as text"
  putStrLn "File acquisition: content/fingerprint capture, stable SHA-256, changes and invalid UTF-8 passed."
