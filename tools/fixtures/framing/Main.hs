module Main where

import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Runtime.Json
import Kyyn.Runtime.Transport
import System.Environment (getArgs)
import Data.Aeson (Value(..), toJSON)

main :: IO ()
main = withTransport $ \transport -> do
  arguments <- getArgs
  case arguments of
    ["fail"] -> writeValue transport (toJSON [encodeWith stringCodec (replicate 20000 'x'), Null])
    _ -> do
      (metadata,body) <- readFrame transport
      value <- either fail pure (parseValue (Text.unpack (Text.decodeUtf8 metadata)))
      writeValueFrame transport value body
