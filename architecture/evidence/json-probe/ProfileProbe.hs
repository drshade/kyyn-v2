module Main where

import Text.JSON.Types
import Text.JSON.String
import System.IO

profile :: JSValue -> Either String JSValue
profile JSNull = Left "null is outside the profile"
profile (JSRational _ _) = Left "numbers must be strings"
profile (JSBool b) = Right (JSBool b)
profile (JSString s) = JSString . toJSString <$> scalarText (fromJSString s)
profile (JSArray xs) = JSArray <$> mapM profile xs
profile (JSObject o) = do
  fields <- mapM field (firstKeys [] (fromJSObject o))
  pure (JSObject (toJSObject fields))
  where
    field (key, value) = (,) <$> scalarText key <*> profile value
    firstKeys _ [] = []
    firstKeys seen ((key,value):rest)
      | key `elem` seen = firstKeys seen rest
      | otherwise = (key,value) : firstKeys (key:seen) rest

scalarText :: String -> Either String String
scalarText s
  | any (\c -> c >= '\xD800' && c <= '\xDFFF') s = Left "surrogate is outside the profile"
  | otherwise = Right s

main :: IO ()
main = do
  input <- getLine
  case runGetJSON readJSValue input >>= profile of
    Left err -> do
      hPutStrLn stderr err
      putStrLn "{\"error\":true}"
    Right value -> putStrLn (showJSValue value "")
