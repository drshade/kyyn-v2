{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Build.Sources (sourceFiles, moduleHeader) where

import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import Data.List (sort)
import GHC
import GHC.Parser.Header (getImports, getOptions)
import GHC.Driver.Config.Parser (initParserOpts)
import GHC.Data.StringBuffer (hGetStringBuffer)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>), takeExtension)

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
