{-# LANGUAGE TemplateHaskell #-}
module Kyyn.Guide (guideResponse) where

import Data.Aeson (object, (.=))
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Language.Haskell.TH.Syntax (addDependentFile, lift, runIO)
import Kyyn.Surfaces.Result (Response, success)

guideResponse :: Response
guideResponse = success (object ["markdown" .= markdown]) (lines markdown)

markdown :: String
markdown = $(do
  -- Cabal compiles this executable from host/kyyn.
  let path = "../../docs/guide.md"
  addDependentFile path
  bytes <- runIO (Bytes.readFile path)
  case Text.decodeUtf8' bytes of
    Left problem -> fail (show problem)
    Right contents -> lift (Text.unpack contents))
