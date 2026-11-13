{-# LANGUAGE TemplateHaskell #-}
module Kyyn.Web.Assets (inspectionAsset) where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir, embedFile)
import Data.Text (Text)
import qualified Data.Text as Text
import Language.Haskell.TH.Syntax (loc_filename, runIO)
import qualified Language.Haskell.TH.Syntax as TH
import System.Environment (getEnv)
import System.FilePath ((</>), takeDirectory)

inspectionAsset :: [Text] -> Maybe ByteString
inspectionAsset ("vendor":path) = lookup (Text.unpack (Text.intercalate "/" path)) vendor
inspectionAsset ["inspection.mjs"] = Just script
inspectionAsset ["run-viewer.mjs"] = Just runScript
inspectionAsset ["run-viewer.css"] = Just runStyle
inspectionAsset _ = Nothing

script :: ByteString
script = $(do
  source <- loc_filename <$> TH.location
  embedFile (takeDirectory source </> "../../../web/inspection.mjs"))

runScript :: ByteString
runScript = $(do
  source <- loc_filename <$> TH.location
  embedFile (takeDirectory source </> "../../../web/run-viewer.mjs"))
runStyle :: ByteString
runStyle = $(do
  source <- loc_filename <$> TH.location
  embedFile (takeDirectory source </> "../../../web/run-viewer.css"))

vendor :: [(FilePath,ByteString)]
vendor = $(runIO (getEnv "KYYN_WEB_VENDOR_DIR") >>= embedDir)
