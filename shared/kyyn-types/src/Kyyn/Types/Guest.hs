{-# LANGUAGE DeriveAnyClass, DeriveGeneric, OverloadedStrings #-}
module Kyyn.Types.Guest
  ( GuestDescription(..), DescribedContract(..), EntryDescription(..), ExportDescription(..)
  , protocolIdentity, describeContract
  ) where

import Data.Aeson (ToJSON, FromJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Kyyn.Types.Contract
import Kyyn.Types.SchemaMetadata

-- Protocol equality selects the current interface; there is no negotiation.
protocolIdentity :: Text
protocolIdentity = "kyyn-guest"

data DescribedContract = DescribedContract
  { structure :: Description, metadata :: SchemaMetadata, identity :: Text
  , loadedSources :: [Text]
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

data EntryDescription = EntryDescription
  { entryName :: Text, entryKind :: Text
  , entryContracts :: [(Text,DescribedContract)], capabilities :: [Text]
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

data ExportDescription = ExportDescription
  { exportModule :: Text, exportName :: Text, exportSignature :: Text, exportSource :: Text, exportKind :: Text
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

data GuestDescription = GuestDescription
  { protocol :: Text, entries :: [EntryDescription], exports :: [ExportDescription]
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

describeContract :: Description -> SchemaMetadata -> [Text] -> DescribedContract
describeContract description annotations sources = DescribedContract description annotations
  (fingerprint (contractIdentity description annotations)) sources
