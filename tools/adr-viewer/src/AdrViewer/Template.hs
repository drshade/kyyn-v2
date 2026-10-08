-- | The viewer page, embedded at compile time so @render@ needs no data files.
{-# LANGUAGE TemplateHaskell #-}
module AdrViewer.Template (viewerTemplate) where

import Language.Haskell.TH.Syntax (addDependentFile, lift, runIO)
import System.IO (IOMode(..), hGetContents', hSetEncoding, utf8, withFile)

viewerTemplate :: String
viewerTemplate = $(do
  let path = "template/viewer.html"
  addDependentFile path
  contents <- runIO (withFile path ReadMode (\h -> hSetEncoding h utf8 >> hGetContents' h))
  lift contents)
