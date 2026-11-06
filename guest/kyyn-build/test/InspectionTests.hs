-- GHC-owned export inspection: source closure, explicit exports, namespaces,
-- record fields without selectors, and source rejection before an adapter exists.
{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (unless)
import Data.List (sort)
import qualified Data.Text as Text
import System.Directory (withCurrentDirectory)
import System.Process (readProcess)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Build.Inspection
import Kyyn.Build.Manifest (parseManifest)
import Kyyn.Types.Guest

main :: IO ()
main = do
  compilerOutput <- readProcess "ghc" ["--print-libdir"] ""
  libdir <- case lines compilerOutput of
    [path] -> pure path
    _ -> fail "Compiler did not identify its libdir"
  withSystemTempDirectory "kyyn-ghc-inspection" $ \directory -> withCurrentDirectory directory $ do
    writeFile "Types.hs" (unlines
      ["{-# LANGUAGE NoFieldSelectors #-}","module Types (Root(..)) where",
       "data Root = Root { count :: Integer }"])
    writeFile "Schema.hs" (unlines
      ["module Schema (Root(..), total) where","import Types",
       "total :: Root -> Integer","total (Root n) = n", "private :: Bool", "private = True"])
    (sources,exports) <- inspectExports libdir ["."] [] ["Schema","Schema"]
    unless (sort sources == ["Schema.hs","Types.hs"]) (fail ("Wrong schema closure: " ++ show sources))
    let values = [(entry.exportName,entry.exportKind) | entry <- exports]
    unless (("Root",ExportType) `elem` values && ("Root",ExportConstructor) `elem` values && ("total",ExportValue) `elem` values)
      (fail ("Compiler export namespaces missing: " ++ show values))
    unless (all ((/= "private") . exportName) exports) (fail "Private implementation leaked into API")
    unless (any (\entry -> entry.exportName == "total" && "Integer" `Text.isInfixOf` entry.exportSignature) exports)
      (fail "Compiler signature missing")
    (packageSources,packageExports) <- inspectExports libdir ["."] [] ["Data.Maybe"]
    unless (null packageSources && any ((== "fromMaybe") . exportName) packageExports)
      (fail "Locked library export inspection failed")
    writeFile "Main.hs" (unlines ["module Main (value) where","value :: Integer","value = 1"])
    (_,mainExports) <- inspectExports libdir ["."] [] ["Main"]
    unless (any ((== "value") . exportName) mainExports) (fail "Authored Main required an IO entry")
    writeFile "Broken.hs" (unlines ["module Broken where","bad :: Integer","bad = True"])
    failed <- try (inspectExports libdir ["."] [] ["Broken"]) :: IO (Either SomeException ([FilePath],[ExportDescription]))
    case failed of
      Left _ -> pure ()
      Right _ -> fail "Invalid authored source passed compiler inspection"
  putStrLn "GHC export inspection and source rejection checks passed."
  let validManifest = Text.unlines
        ["{ schemaType = \"Schema.Root\", schemaMetadata = \"Schema.metadata\", validator = \"Schema.validate\"",
         ", queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }",
         ", tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"]
  case parseManifest validManifest of
    Left problem -> fail problem
    Right _ -> pure ()
  let rejects source = case parseManifest source of
        Left _ -> pure ()
        Right _ -> fail "Malformed manifest accepted"
  rejects "./some-other-manifest.dhall"
  rejects (Text.replace "Schema.Root" "Schema.Root; error \"injected\"" validManifest)
  rejects (Text.replace "Schema.validate" "validate" validManifest)
  rejects (Text.replace ", tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }"
    ", tools = [] : List Natural" validManifest)
  putStrLn "Manifest references, imports and empty-list type checks passed."
