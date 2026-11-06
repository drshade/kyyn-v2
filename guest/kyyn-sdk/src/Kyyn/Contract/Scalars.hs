{-# LANGUAGE FlexibleInstances, ScopedTypeVariables, TypeApplications, OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot, DuplicateRecordFields #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | The SDK supplies one Contract instance for library scalars and shared values.
module Kyyn.Contract.Scalars
  ( integerText, decimalText, naturalText, dayText, instantText, probabilityText
  , factIdText, blobCodec, fixedInfo
  ) where

import Agentic.Contract
import Data.Fixed (Fixed, HasResolution)
import Data.Proxy (Proxy(..))
import Data.Time (Day, UTCTime)
import Numeric.Natural (Natural)
import Type.Reflection (Typeable)
import Kyyn.Types.Fact (factIdText)
import Kyyn.Types.Scalar
import Kyyn.Types.Blob (blobCodec)

instance Contract Natural where
  contract = scalar (ScalarInfo "Numeric.Natural.Natural" []) (Just naturalText)
instance (HasResolution a, Typeable a) => Contract (Fixed a) where
  contract = scalar (fixedInfo (Proxy @a)) (Just decimalText)
instance Contract Day where
  contract = scalar (ScalarInfo "Data.Time.Day" []) (Just dayText)
instance Contract UTCTime where
  contract = scalar (ScalarInfo "Data.Time.UTCTime" []) (Just instantText)
