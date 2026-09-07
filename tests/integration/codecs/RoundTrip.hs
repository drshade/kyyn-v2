module Main where

import KyynGeneratedCodec (rootCodec)
import Kyyn.Runtime.Json
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  input <- getLine
  case parseValue input >>= decodeWith rootCodec >>= printValue . encodeWith rootCodec of
    Left message -> do
      hPutStrLn stderr message
      putStrLn "{\"error\":true}"
    Right output -> putStrLn output
