{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.GuestBuild (GuestSelection(..), DiscoverySelection(..), RecipeReference(..), EvolutionSelection(..), canonicalSelection) where

import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), object, (.=), (.:), withObject)
import Data.Text (Text)
import Data.List (nub, sort)
import Kyyn.Types.Json (exactObject, optionalValue, parseOptionalValue)

-- Private build input captured with the KB, rather than an environment override.
data GuestSelection = RootEntries | PluginEntries | RecipeEntries [RecipeReference] | EvolutionEntries EvolutionSelection | TargetEvolutionEntries [RecipeReference] (Maybe [Text]) | DiscoveryEntries DiscoverySelection deriving (Eq, Show)
data DiscoverySelection = RootSchema | RootApi (Maybe Text) | ModuleExports [Text] deriving (Eq, Show)

-- Before source lives below .kyyn-before/ and transformation source below
-- .kyyn-change/. No fact or recipe state values are build inputs.
-- Nothing selects execution; Just modules selects discovery without the body.
data EvolutionSelection = EvolutionSelection Text Text [RecipeReference] (Maybe RecipeReference) (Maybe [Text]) deriving (Eq, Show)
instance ToJSON EvolutionSelection where
  toJSON (EvolutionSelection schema metadata references recipe modules) = object
    ["beforeType" .= schema,"beforeMetadata" .= metadata,"beforeRecipes" .= sort (nub references),"recipe" .= optionalValue recipe,"modules" .= optionalValue modules]
instance FromJSON EvolutionSelection where
  parseJSON = exactObject "evolution selection details" ["beforeType","beforeMetadata","beforeRecipes","recipe","modules"] $ \fields ->
    EvolutionSelection <$> fields .: "beforeType" <*> fields .: "beforeMetadata" <*> fields .: "beforeRecipes"
      <*> (fields .: "recipe" >>= parseOptionalValue) <*> (fields .: "modules" >>= parseOptionalValue)

-- Recipe data stays on the host. Only referenced code belongs to the build.
data RecipeReference = OpenState Text | ClosedFlow Text deriving (Eq, Ord, Show)
canonicalSelection :: GuestSelection -> GuestSelection
canonicalSelection (RecipeEntries references) = RecipeEntries (sort (nub references))
canonicalSelection (EvolutionEntries (EvolutionSelection schema metadata references recipe modules)) =
  EvolutionEntries (EvolutionSelection schema metadata (sort (nub references)) recipe (sort . nub <$> modules))
canonicalSelection (TargetEvolutionEntries references modules) = TargetEvolutionEntries (sort (nub references)) (sort . nub <$> modules)
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
  toJSON (TargetEvolutionEntries references modules) = object ["selection" .= String "targetEvolution", "references" .= sort (nub references), "modules" .= optionalValue modules]
  toJSON (EvolutionEntries details) = object ["selection" .= String "evolution","details" .= details]
  toJSON (DiscoveryEntries (RootApi selected)) = object ["selection" .= String "rootApi","selected" .= optionalValue selected]
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
      "targetEvolution" -> exactObject "target evolution selection" ["selection","references","modules"]
        (\selected -> canonicalSelection <$> (TargetEvolutionEntries <$> selected .: "references" <*>
          (selected .: "modules" >>= parseOptionalValue))) value
      "evolution" -> exactObject "evolution selection" ["selection","details"]
        (\selected -> canonicalSelection . EvolutionEntries <$> selected .: "details") value
      "rootApi" -> exactObject "root API selection" ["selection","selected"]
        (\selected -> DiscoveryEntries . RootApi <$> (selected .: "selected" >>= parseOptionalValue)) value
      "schema" -> exactObject "schema selection" ["selection"] (const (pure (DiscoveryEntries RootSchema))) value
      "modules" -> exactObject "module selection" ["selection","modules"]
        (\selected -> DiscoveryEntries . ModuleExports <$> selected .: "modules") value
      _ -> fail "Unsupported guest build selection") value
