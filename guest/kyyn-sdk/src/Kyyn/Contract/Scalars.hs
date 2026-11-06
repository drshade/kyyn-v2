{-# LANGUAGE FlexibleInstances, ScopedTypeVariables, TypeApplications, OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | The SDK supplies one Contract instance for library scalars and shared values.
module Kyyn.Contract.Scalars
  ( integerText, decimalText, naturalText, dayText, instantText, probabilityText
  , factIdText, blobCodec, fixedInfo
  ) where

import Agentic.Contract
import qualified Agentic.Codec as C
import qualified Agentic.Schema as S
import Agentic.Questions (Probability, basisPoints, fromBasisPoints)
import Agentic.Value (Value(..))
import Data.Fixed (Fixed(..), HasResolution(..), showFixed)
import Data.Proxy (Proxy(..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Numeric.Natural (Natural)
import Text.Read (readMaybe)
import Type.Reflection (Typeable)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.Blob (BlobRef(..))

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

factIdText :: Codec FactId
factIdText = textual (\(FactId t) -> t) (Right . FactId)

-- | The caller supplies the structural optional codec so this leaf obeys the
-- selected projection's null/tag policy without losing BlobRef's scalar identity.
blobCodec :: Codec (Maybe Text) -> Codec BlobRef
blobCodec optionalText = C.record "" $
  BlobRef <$> C.requiredWith "sha256" Nothing digest (\(BlobRef x _ _ _) -> x)
          <*> C.requiredWith "size" Nothing size (\(BlobRef _ x _ _) -> x)
          <*> C.requiredWith "mediaType" Nothing text (\(BlobRef _ _ x _) -> x)
          <*> C.requiredWith "name" Nothing optionalText (\(BlobRef _ _ _ x) -> x)
  where
    text = textual id Right
    digest = textual id $ \t -> if T.length t == 64 && T.all (`elem` ("0123456789abcdef" :: String)) t
      then Right t else Left "expected a lowercase SHA-256 digest"
    size = textual (T.pack . show) $ \t -> do
      n <- integerText.decode (String t)
      if n < 0 then Left "blob size must be nonnegative" else Right n

instance Contract Natural where
  contract = scalar (ScalarInfo "Numeric.Natural.Natural" []) (Just naturalText)
instance (HasResolution a, Typeable a) => Contract (Fixed a) where
  contract = scalar (fixedInfo (Proxy @a)) (Just decimalText)
instance Contract Day where
  contract = scalar (ScalarInfo "Data.Time.Day" []) (Just dayText)
instance Contract UTCTime where
  contract = scalar (ScalarInfo "Data.Time.UTCTime" []) (Just instantText)
instance Contract FactId where
  contract = scalar (ScalarInfo "Kyyn.FactId" []) (Just factIdText)
instance (Typeable a, Contract a) => Contract (Fact a) where
  contract = nominal $ record "" $
    Fact <$> required "id" "" (\(Fact x _) -> x) <*> required "value" "" (\(Fact _ x) -> x)
instance Contract BlobRef where
  contract = scalar (ScalarInfo "Kyyn.BlobRef" []) model
    where model = either (const Nothing) (Just . blobCodec) (compileModel (contract @(Maybe Text)))
