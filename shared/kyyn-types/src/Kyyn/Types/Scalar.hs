{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, TypeApplications, OverloadedRecordDot #-}
module Kyyn.Types.Scalar
  ( textual, integerText, naturalText, decimalText, dayText, instantText
  , probabilityText, fixedInfo, validateDecimalText ) where

import Agentic.Contract (Codec, ScalarInfo(..))
import Agentic.Questions (Probability, basisPoints, fromBasisPoints)
import Data.Fixed (Fixed, HasResolution(..), showFixed, E0, E1, E2, E3, E6, E9, E12)
import Data.Proxy (Proxy(..))
import Data.Time (Day, UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Numeric.Natural (Natural)
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

naturalText :: Codec Natural
naturalText = textual (T.pack . show) $ \t -> do
  n <- integerText.decode (String t)
  if n < 0 then Left "expected a nonnegative integer" else Right (fromInteger n)

fixedInfo :: forall a. HasResolution a => Proxy a -> ScalarInfo
fixedInfo _ = ScalarInfo "Data.Fixed.Fixed" [("resolution", T.pack (show (resolution (Proxy @a))))]

decimalText :: forall a. HasResolution a => Codec (Fixed a)
decimalText = textual (T.pack . showFixed True) $ \t -> case readMaybe (T.unpack t) of
  Just n | T.pack (showFixed True (n :: Fixed a)) == t -> Right n
  _ -> Left "expected canonical exact decimal text"

dayText :: Codec Day
dayText = textual (T.pack . formatTime defaultTimeLocale "%F") $ \t ->
  case parseTimeM True defaultTimeLocale "%F" (T.unpack t) of
    Just d | T.pack (formatTime defaultTimeLocale "%F" (d :: Day)) == t -> Right d
    _ -> Left "expected canonical ISO date"

instantText :: Codec UTCTime
instantText = textual (T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ") $ \t ->
  case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t) of
    Just d | T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (d :: UTCTime)) == t -> Right d
    _ -> Left "expected canonical UTC instant"

probabilityText :: Codec Probability
probabilityText = textual (T.pack . show . basisPoints) $ \t -> do
  n <- integerText.decode (String t)
  if n < 0 || n > 10000 then Left "basis points must be between 0 and 10000"
    else Right (fromBasisPoints (fromInteger n))


validateDecimalText :: Integer -> Text -> Either Text ()
validateDecimalText selected value = case selected of
  1 -> check (decimalText @E0)
  10 -> check (decimalText @E1)
  100 -> check (decimalText @E2)
  1000 -> check (decimalText @E3)
  1000000 -> check (decimalText @E6)
  1000000000 -> check (decimalText @E9)
  1000000000000 -> check (decimalText @E12)
  _ -> Left "unsupported fixed-point resolution"
  where
    check :: Codec a -> Either Text ()
    check codec = () <$ codec.decode (String value)
