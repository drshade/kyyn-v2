{-# LANGUAGE OverloadedStrings #-}
-- | Private evolution transport. Stored values are structural, not contracts.
module Kyyn.Types.SnapshotWire
  ( SnapshotWire(..), ValueWire(..), RecipeWire(..), DefinitionWire(..) ) where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import Kyyn.Types.StoredShape (StoredShape)
import Kyyn.Types.Json (exactObject)

data ValueWire = ValueWire StoredShape Value deriving (Eq, Show)
data DefinitionWire = OpenWire Text Text | ClosedWire Text deriving (Eq, Show)
data RecipeWire = RecipeWire DefinitionWire ValueWire deriving (Eq, Show)
data SnapshotWire = SnapshotWire
  [(Text,ValueWire)] [(Text,[(Text,ValueWire)])] [(Text,RecipeWire)]
  deriving (Eq, Show)

instance ToJSON ValueWire where
  toJSON (ValueWire shape value) = object ["shape" .= shape,"value" .= value]
instance FromJSON ValueWire where
  parseJSON = withObject "Stored value" $ \o -> do
    exactObject "Stored value" ["shape","value"] (const (pure ())) (Object o)
    ValueWire <$> o .: "shape" <*> o .: "value"
instance ToJSON DefinitionWire where
  toJSON (OpenWire instructions stateType) = object
    ["kind" .= String "open","instructions" .= instructions,"stateType" .= stateType]
  toJSON (ClosedWire flow) = object ["kind" .= String "closed","flow" .= flow]
instance FromJSON DefinitionWire where
  parseJSON = withObject "Stored definition" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "open" -> exactObject "Open definition" ["kind","instructions","stateType"] (const (pure ())) (Object o) >>
        (OpenWire <$> o .: "instructions" <*> o .: "stateType")
      "closed" -> exactObject "Closed definition" ["kind","flow"] (const (pure ())) (Object o) >> (ClosedWire <$> o .: "flow")
      _ -> fail "Unknown stored definition kind"
instance ToJSON RecipeWire where
  toJSON (RecipeWire definition state) = object ["definition" .= definition,"state" .= state]
instance FromJSON RecipeWire where
  parseJSON = withObject "Stored recipe" $ \o -> do
    exactObject "Stored recipe" ["definition","state"] (const (pure ())) (Object o)
    RecipeWire <$> o .: "definition" <*> o .: "state"
instance ToJSON SnapshotWire where
  toJSON (SnapshotWire fields collections recipes) = object
    ["fields" .= fields,"collections" .= collections,"recipes" .= recipes]
instance FromJSON SnapshotWire where
  parseJSON = withObject "Stored snapshot" $ \o -> do
    exactObject "Stored snapshot" ["fields","collections","recipes"] (const (pure ())) (Object o)
    SnapshotWire <$> o .: "fields" <*> o .: "collections" <*> o .: "recipes"
