{-# LANGUAGE OverloadedStrings #-}
module Main where
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy.Char8 as B
import qualified Data.Text as T

main :: IO ()
main = do
  B.putStrLn (A.encode (A.object ["text" A..= ("München 日本語 🦋\n\t\0" :: T.Text)]))
  print (A.eitherDecode "{\"x\":1,\"x\":2}" :: Either String A.Value)
