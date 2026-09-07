module Main where

import Text.JSON.Types
import Text.JSON.String
import System.IO

main :: IO ()
main = do
  input <- getLine
  case runGetJSON readJSValue input of
    Left err -> do
      hPutStrLn stderr err
      putStrLn "{\"error\":true}"
    Right value -> putStrLn (showJSValue value "")
