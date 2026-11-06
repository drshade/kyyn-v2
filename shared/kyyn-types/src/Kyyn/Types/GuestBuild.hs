{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.GuestBuild (GuestSelection(..), DiscoverySelection(..), RecipeReference(..), canonicalSelection) where

import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), object, (.=), (.:), withObject)
import Data.Text (Text)
import Data.List (nub, sort)
import Kyyn.Types.Json (exactObject)

-- Private build input captured with the KB, rather than an environment override.
data GuestSelection = RootEntries | PluginEntries | RecipeEntries [RecipeReference] | EvolutionEntry | DiscoveryEntries DiscoverySelection deriving (Eq, Show)
data DiscoverySelection = RootSchema | ModuleExports [Text] deriving (Eq, Show)

-- Recipe data stays on the host. Only referenced code belongs to the build.
data RecipeReference = OpenState Text | ClosedFlow Text deriving (Eq, Ord, Show)
canonicalSelection :: GuestSelection -> GuestSelection
canonicalSelection (RecipeEntries references) = RecipeEntries (sort (nub references))
canonicalSelection selected = selected

instance ToJSON RecipeReference where
  toJSON (OpenState name) = object ["kind" .= String "state","name" .= name]
  toJSON (ClosedFlow name) = object ["kind" .= String "flow","name" .= name]
instance FromJSON RecipeReference where
  parseJSON = exactObject "recipe reference" ["kind","name"] $ \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "state" -> OpenState <$> fields .: "name"
      "flow" -> ClosedFlow <$> fields .: "name"
      _ -> fail "Unknown recipe reference kind"

instance ToJSON GuestSelection where
  toJSON RootEntries = object ["selection" .= String "root"]
  toJSON PluginEntries = object ["selection" .= String "plugins"]
  toJSON (RecipeEntries references) = object ["selection" .= String "recipes","references" .= sort (nub references)]
  toJSON EvolutionEntry = object ["selection" .= String "evolution"]
  toJSON (DiscoveryEntries RootSchema) = object ["selection" .= String "schema"]
  toJSON (DiscoveryEntries (ModuleExports modules)) = object ["selection" .= String "modules","modules" .= modules]
instance FromJSON GuestSelection where
  parseJSON value = withObject "guest build selection" (\fields -> do
    selection <- fields .: "selection"
    case selection :: Text of
      "root" -> exactObject "root selection" ["selection"] (const (pure RootEntries)) value
      "plugins" -> exactObject "plugin selection" ["selection"] (const (pure PluginEntries)) value
      "recipes" -> exactObject "recipe selection" ["selection","references"]
        (\selected -> canonicalSelection . RecipeEntries <$> selected .: "references") value
      "evolution" -> exactObject "evolution selection" ["selection"] (const (pure EvolutionEntry)) value
      "schema" -> exactObject "schema selection" ["selection"] (const (pure (DiscoveryEntries RootSchema))) value
      "modules" -> exactObject "module selection" ["selection","modules"]
        (\selected -> DiscoveryEntries . ModuleExports <$> selected .: "modules") value
      _ -> fail "Unsupported guest build selection") value
