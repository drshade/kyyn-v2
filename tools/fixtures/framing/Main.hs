module Main where

import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Runtime.Json
import Kyyn.Runtime.Transport
import System.Environment (getArgs)
import Text.JSON.Types (JSValue(..))

main :: IO ()
main = withTransport $ \transport -> do
  arguments <- getArgs
  case arguments of
    ["fail"] -> writeValue transport (JSArray [encodeWith stringCodec (replicate 20000 'x'), JSNull])
    _ -> do
      (metadata,body) <- readFrame transport
      value <- either fail pure (parseValue (Text.unpack (Text.decodeUtf8 metadata)))
      writeValueFrame transport value body
