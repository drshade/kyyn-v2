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
    ["surrogate"] -> writeValue transport (toJSON [encodeWith stringCodec (replicate 20000 'x'), encodeWith stringCodec "\xD800"])
    ["surrogate-key"] -> writeValue transport (record [("\xD800",Bool True)])
    ["duplicate"] -> writeValue transport (record [("x",Bool True),("x",Bool False)])
    _ -> do
      (metadata,body) <- readFrame transport
      value <- either fail pure (parseValue (Text.unpack (Text.decodeUtf8 metadata)))
      writeValueFrame transport value body
