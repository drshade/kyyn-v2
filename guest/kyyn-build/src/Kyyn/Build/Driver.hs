{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Build.Driver (buildGuest) where

import Control.Monad (unless, forM)
import Data.Aeson (eitherDecodeStrict')
import qualified Data.ByteString as Bytes
import Data.Char (isAlphaNum, isLower)
import Data.List (nub, intercalate)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Directory (createDirectoryIfMissing, doesFileExist, doesPathExist, makeAbsolute, withCurrentDirectory)
import System.FilePath ((</>), takeDirectory)
import System.Process (callProcess, readProcess)
import Kyyn.Build.Inspection
import Kyyn.Build.Manifest
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata

-- The compiler and source are selected by the KB's build, never the host's PATH.
-- Both inspection and compilation use that exact compiler package environment.
buildGuest :: FilePath -> FilePath -> FilePath -> IO ()
buildGuest compiler source output = do
  destination <- makeAbsolute output
  withCurrentDirectory source $ do
    manifest <- Text.readFile "kb.dhall" >>= either fail pure . parseManifest
    unless (null manifest.tools && null manifest.outputs)
      (fail "Guest build: tool and output adapters are not implemented yet")
    libdir <- readProcess compiler ["--print-libdir"] "" >>= singleLine "compiler libdir"
    packages <- packageOptions libdir
    let generated = ".kyyn-generated"
    occupied <- or <$> traverse doesFileExist ["src" </> "KyynQueryBindings" ++ extension | extension <- [".hs",".lhs"]]
    unless (not occupied) (fail "Authored source collides with generated KyynQueryBindings")
    existing <- doesPathExist generated
    unless (not existing) (fail "Guest build requires a fresh .kyyn-generated directory")
    createDirectoryIfMissing True generated
    let name = Text.unpack . referenceName
        moduleName = Text.unpack . referenceModule
        rootModules = nub [moduleName manifest.schemaType,moduleName manifest.schemaMetadata]
    (rootSources,_) <- inspectExports libdir ["src"] packages rootModules
    -- This prepass cannot see generated bindings: Root determines their types.
    writeFile (generated </> "SchemaEntry.hs") (unlines
      (["{-# LANGUAGE TypeApplications #-}","module Main where",
        "import Kyyn.Contract", "import qualified Data.Aeson as Json",
        "import qualified Data.ByteString.Lazy as Bytes"] ++
       map ("import qualified " ++) rootModules ++
       ["main :: IO ()", "main = case compileContract (contract @" ++ name manifest.schemaType ++ ") of",
        "  Left problem -> fail (show problem)",
        "  Right _ -> Bytes.writeFile \".kyyn-generated/metadata.json\" (Json.encode " ++ name manifest.schemaMetadata ++ ")"]))
    compile compiler generated "schema" (packages ++ ["-isrc"]) (generated </> "SchemaEntry.hs") (generated </> "schema-entry")
    callProcess ("./" ++ generated </> "schema-entry") []
    metadata <- Bytes.readFile (generated </> "metadata.json") >>= either fail pure . eitherDecodeStrict'
    generatedBindings <- either fail pure (bindings manifest metadata)
    writeFile (generated </> "KyynQueryBindings.hs") generatedBindings
    let selectedModules = nub (rootModules ++ [moduleName manifest.validator] ++ concat
          [[moduleName q.queryImplementation,moduleName q.inputType,moduleName q.inputMetadata,
            moduleName q.resultType,moduleName q.resultMetadata] | q <- manifest.queries])
    (_,exports) <- inspectExports libdir ["src",generated] packages selectedModules
    querySources <- forM manifest.queries $ \q -> do
      (arguments,_) <- inspectExports libdir ["src",generated] packages [moduleName q.inputType,moduleName q.inputMetadata]
      (results,_) <- inspectExports libdir ["src",generated] packages [moduleName q.resultType,moduleName q.resultMetadata]
      pure (q,arguments,results)
    -- Runtime is a public sublibrary, deliberately absent from the author SDK.
    let packageTool = takeDirectory compiler </> "ghc-pkg"
    runtime <- readProcess packageTool ["field","z-kyyn-sdk-z-runtime","id","--simple-output"] "" >>= singleLine "runtime package"
    writeFile (generated </> "GuestEntry.hs") (unlines
      (["{-# LANGUAGE TypeApplications, OverloadedStrings #-}","module Main where",
        "import Kyyn.Runtime.Guest", "import Kyyn.Types.Guest"] ++
       map ("import qualified " ++) selectedModules ++
       ["main :: IO ()", "main = runGuest " ++ showExports exports ++ " [" ++
        intercalate ",\n  "
          (("validationEntry @" ++ name manifest.schemaType ++ " " ++ name manifest.schemaMetadata ++ " " ++ show rootSources ++ " " ++ name manifest.validator) :
           ["queryEntry @" ++ name manifest.schemaType ++ " @" ++ name q.inputType ++ " @" ++ name q.resultType ++
            " " ++ show (Text.unpack q.queryName) ++
            " (" ++ name manifest.schemaMetadata ++ "," ++ show rootSources ++ ")" ++
            " (" ++ name q.inputMetadata ++ "," ++ show arguments ++ ")" ++
            " (" ++ name q.resultMetadata ++ "," ++ show results ++ ") " ++ name q.queryImplementation
              | (q,arguments,results) <- querySources]) ++ "]"]))
    -- GHC recompiles authored code with the same options used during discovery.
    compile compiler generated "guest" (packages ++ ["-isrc", "-i" ++ generated,"-package-id",runtime])
      (generated </> "GuestEntry.hs") destination

compile :: FilePath -> FilePath -> String -> [String] -> FilePath -> FilePath -> IO ()
compile compiler generated stage options entry output = do
  let objects = generated </> stage
  createDirectoryIfMissing True objects
  callProcess compiler (["--make","-XGHC2021","-odir",objects,"-hidir",objects] ++ options ++ [entry,"-o",output])

singleLine :: String -> String -> IO String
singleLine label output = case lines output of
  [value] | not (null value) -> pure value
  _ -> fail ("Expected one " ++ label)

bindings :: Manifest -> SchemaMetadata -> Either String String
bindings manifest (SchemaMetadata _ _ collections) = do
  unless (all (validField . (\(CollectionDecl _ field _) -> field)) collections)
    (Left "Collection metadata must name a Haskell record field")
  pure (unlines
    (["{-# LANGUAGE DataKinds, TypeApplications, OverloadedStrings #-}",
      "{-# OPTIONS_GHC -Wno-missing-signatures #-}",
      "module KyynQueryBindings where", "import GHC.Records (getField)",
      "import qualified Kyyn.Types.Query as Query",
      "import qualified " ++ Text.unpack (referenceModule manifest.schemaType),
      "type Query a = Query.Query " ++ Text.unpack (referenceName manifest.schemaType) ++ " a"] ++
     [Text.unpack field ++ " = Query.CollectionBinding " ++ show (Text.unpack collection) ++
      " (\\root -> getField @" ++ show (Text.unpack field) ++ " (root :: " ++ Text.unpack (referenceName manifest.schemaType) ++ "))"
         | CollectionDecl collection field _ <- collections]))
  where
    validField field = case Text.uncons field of
      Just (first,rest) -> (isLower first || first == '_') &&
        Text.all (\c -> isAlphaNum c || c == '_' || c == '\'') rest
      Nothing -> False

showExports :: [ExportDescription] -> String
showExports entries = "[" ++ intercalate "," ["ExportDescription " ++ unwords
  (map (show . Text.unpack) [e.exportModule,e.exportName,e.exportSignature,e.exportSource,e.exportKind]) | e <- entries] ++ "]"
