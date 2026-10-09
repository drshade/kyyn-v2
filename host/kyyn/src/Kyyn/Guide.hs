{-# LANGUAGE TemplateHaskell #-}
module Kyyn.Guide (guideResponse) where

import Data.Aeson (object, (.=))
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Language.Haskell.TH.Syntax (addDependentFile, lift, runIO, location, loc_filename)
import Kyyn.Surfaces.Result (Response, success)
import System.FilePath ((</>), takeDirectory)

guideResponse :: Response
guideResponse = success (object ["markdown" .= markdown]) (lines markdown)

markdown :: String
markdown = $(do
  source <- loc_filename <$> location
  let path = takeDirectory source </> "../../guide.md"
  addDependentFile path
  bytes <- runIO (Bytes.readFile path)
  case Text.decodeUtf8' bytes of
    Left problem -> fail (show problem)
    Right contents -> lift (Text.unpack contents))
