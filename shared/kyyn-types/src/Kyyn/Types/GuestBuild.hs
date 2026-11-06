{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.GuestBuild (GuestSelection(..), DiscoverySelection(..)) where

import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), object, (.=), (.:), withObject)
import Data.Text (Text)
import Kyyn.Types.Json (exactObject)

-- Private build input captured with the KB, rather than an environment override.
data GuestSelection = RootEntries | PluginEntries | EvolutionEntry | DiscoveryEntries DiscoverySelection deriving (Eq, Show)
data DiscoverySelection = RootSchema | ModuleExports [Text] deriving (Eq, Show)

instance ToJSON GuestSelection where
  toJSON RootEntries = object ["selection" .= String "root"]
  toJSON PluginEntries = object ["selection" .= String "plugins"]
  toJSON EvolutionEntry = object ["selection" .= String "evolution"]
  toJSON (DiscoveryEntries RootSchema) = object ["selection" .= String "schema"]
  toJSON (DiscoveryEntries (ModuleExports modules)) = object ["selection" .= String "modules","modules" .= modules]
instance FromJSON GuestSelection where
  parseJSON value = withObject "guest build selection" (\fields -> do
    selection <- fields .: "selection"
    case selection :: Text of
      "root" -> exactObject "root selection" ["selection"] (const (pure RootEntries)) value
      "plugins" -> exactObject "plugin selection" ["selection"] (const (pure PluginEntries)) value
      "evolution" -> exactObject "evolution selection" ["selection"] (const (pure EvolutionEntry)) value
      "schema" -> exactObject "schema selection" ["selection"] (const (pure (DiscoveryEntries RootSchema))) value
      "modules" -> exactObject "module selection" ["selection","modules"]
        (\selected -> DiscoveryEntries . ModuleExports <$> selected .: "modules") value
      _ -> fail "Unsupported guest build selection") value
