{-# LANGUAGE TemplateHaskell #-}
module Kyyn.Web.Assets (inspectionAsset) where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Text (Text)
import qualified Data.Text as Text
import Language.Haskell.TH.Syntax (loc_filename, runIO)
import qualified Language.Haskell.TH.Syntax as TH
import System.Environment (getEnv)
import System.FilePath ((</>), takeDirectory)

inspectionAsset :: [Text] -> Maybe ByteString
inspectionAsset ("vendor":path) = lookup (Text.unpack (Text.intercalate "/" path)) vendor
inspectionAsset path = lookup (Text.unpack (Text.intercalate "/" path)) assets

assets :: [(FilePath,ByteString)]
assets = $(do
  source <- loc_filename <$> TH.location
  embedDir (takeDirectory source </> "../../../web"))

vendor :: [(FilePath,ByteString)]
vendor = $(runIO (getEnv "KYYN_WEB_VENDOR_DIR") >>= embedDir)
