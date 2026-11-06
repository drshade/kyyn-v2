{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.Scalar (textual, integerText) where

import Agentic.Contract (Codec)
import qualified Agentic.Codec as C
import qualified Agentic.Schema as S
import Agentic.Value (Value(..))
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

textual :: (a -> Text) -> (Text -> Either Text a) -> Codec a
textual enc dec = C.primitive (S.SString Nothing) (String . enc) decode
  where
    decode (String t) = dec t
    decode _ = Left "expected canonical text"

integerText :: Codec Integer
integerText = textual (T.pack . show) $ \t -> case readMaybe (T.unpack t) of
  Just n | T.pack (show (n :: Integer)) == t -> Right n
  _ -> Left "expected canonical integer text"

