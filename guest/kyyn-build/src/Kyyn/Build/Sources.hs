{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Build.Sources (sourceFiles, moduleHeader, mergeSources) where

import Control.Monad (forM, unless)
import Control.Monad.IO.Class (liftIO)
import Data.List (nub, sort)
import qualified Data.ByteString as Bytes
import GHC
import GHC.Parser.Header (getImports, getOptions)
import GHC.Driver.Config.Parser (initParserOpts)
import GHC.Data.StringBuffer (hGetStringBuffer)
import System.Directory (doesDirectoryExist, listDirectory, createDirectoryIfMissing)
import System.FilePath ((</>), takeExtension, takeDirectory)

-- Inventory only parses module headers/imports. Unfinished transformation bodies
-- remain available to discovery without being typechecked.
moduleHeader :: FilePath -> FilePath -> IO (String,[String])
moduleHeader libdir path = runGhc (Just libdir) $ do
  initial <- getSessionDynFlags
  logger <- getLogger
  (base,_,_) <- parseDynamicFlags logger initial [noLoc "-XGHC2021"]
  buffer <- liftIO (hGetStringBuffer path)
  let (_,options) = getOptions (initParserOpts base) buffer path
  (configured,_,_) <- parseDynamicFlags logger base options
  parsed <- liftIO (getImports (initParserOpts configured) False buffer path path)
  case parsed of
    Left _ -> liftIO (fail ("GHC rejected module header: " ++ path))
    Right (sourceImports,imports,_,name) -> pure (moduleNameString (unLoc name),
      map (moduleNameString . unLoc . snd) (sourceImports ++ imports))

sourceFiles :: FilePath -> IO [FilePath]
sourceFiles root = do
  present <- doesDirectoryExist root
  if not present then pure [] else do
    entries <- sort <$> listDirectory root
    concat <$> forM entries (\name -> do
      let path = root </> name
      directory <- doesDirectoryExist path
      if directory then sourceFiles path else case takeExtension path of
        ".hs" -> pure [path]
        ".lhs" -> fail ("Only .hs authored Haskell source is supported: " ++ path)
        ".hsc" -> fail ("Only .hs authored Haskell source is supported: " ++ path)
        _ -> pure [])

-- Import-path order must never select between different definitions. Shared
-- byte-identical modules are emitted once; the map retains their source origin.
mergeSources :: FilePath -> FilePath -> [FilePath] -> IO [(FilePath,FilePath)]
mergeSources libdir destination paths = do
  modules <- forM (nub paths) $ \path -> do
    (name,_) <- moduleHeader libdir path
    bytes <- Bytes.readFile path
    pure (name,path,bytes)
  forM (sort (nub [name | (name,_,_) <- modules])) $ \name -> do
    let definitions = [(path,bytes) | (actual,path,bytes) <- modules, actual == name]
    unless (length (nub (map snd definitions)) == 1) (fail
      ("Different definitions of module " ++ name ++ " at " ++ show (map fst definitions) ++
       "; rename modules whose Before and After definitions must coexist"))
    case definitions of
      (origin,bytes):_ -> do
        let output = destination </> map (\c -> if c == '.' then '/' else c) name ++ ".hs"
        createDirectoryIfMissing True (takeDirectory output)
        Bytes.writeFile output bytes
        pure (output,origin)
      [] -> fail "Empty module group"
