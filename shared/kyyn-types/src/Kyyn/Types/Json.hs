module Kyyn.Types.Json (exactObject) where

import Control.Monad (unless)
import Data.Aeson (Value, Object, withObject)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.Aeson.Types (Parser)
import Data.List (sort)

exactObject :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
exactObject label expected parse = withObject label $ \fields -> do
  unless (sort (Keys.keys fields) == sort expected) (fail (label ++ ": unexpected or missing fields"))
  parse fields
