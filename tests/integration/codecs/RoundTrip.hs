module Main where

import KyynGeneratedCodec (rootCodec)
import qualified KyynSecondCodec as Second
import Kyyn.Runtime.Json
import Kyyn.Runtime.Transport
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = withTransport $ \transport -> do
  input <- readJson transport
  case parseValue input >>= decodeWith rootCodec of
    Left message -> do
      hPutStrLn stderr message
      writeJson transport "{\"error\":true}"
    Right output -> writeValue transport (encodeWith Second.rootCodec output)
