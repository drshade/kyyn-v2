{-# LANGUAGE FlexibleInstances, ScopedTypeVariables, TypeApplications, OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | The SDK supplies one Contract instance for library scalars and shared values.
module Kyyn.Contract.Scalars
  ( integerText, decimalText, naturalText, dayText, instantText, probabilityText
  , factIdText, blobCodec, fixedInfo
  ) where

import Agentic.Contract
import Agentic.Questions (Probability, basisPoints, fromBasisPoints)
import Agentic.Value (Value(..))
import Data.Fixed (Fixed(..), HasResolution(..), showFixed)
import Data.Proxy (Proxy(..))
import qualified Data.Text as T
import Data.Time (Day, UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Numeric.Natural (Natural)
import Text.Read (readMaybe)
import Type.Reflection (Typeable)
import Kyyn.Types.Fact (factIdText)
import Kyyn.Types.Scalar (textual, integerText)
import Kyyn.Types.Blob (blobCodec)

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

instance Contract Natural where
  contract = scalar (ScalarInfo "Numeric.Natural.Natural" []) (Just naturalText)
instance (HasResolution a, Typeable a) => Contract (Fixed a) where
  contract = scalar (fixedInfo (Proxy @a)) (Just decimalText)
instance Contract Day where
  contract = scalar (ScalarInfo "Data.Time.Day" []) (Just dayText)
instance Contract UTCTime where
  contract = scalar (ScalarInfo "Data.Time.UTCTime" []) (Just instantText)
