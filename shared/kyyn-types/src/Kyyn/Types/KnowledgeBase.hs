{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.KnowledgeBase (Lifetime(..), Recipe(..), RecipeId(..), FlowEntryRef(..)) where

import Data.Text (Text)
import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), object, (.=), (.:))
import Kyyn.Types.Json (exactObject)

-- | The name of an identified recipe in the selected root.
newtype RecipeId = RecipeId Text deriving (Eq, Show)

data Lifetime = Ordinary | Interactive deriving (Eq, Show)
instance ToJSON Lifetime where
  toJSON Ordinary = object ["tag" .= String "Ordinary"]
  toJSON Interactive = object ["tag" .= String "Interactive"]
instance FromJSON Lifetime where
  parseJSON = exactObject "recipe lifetime" ["tag"] $ \fields -> do
    selected <- fields .: "tag"
    case selected :: Text of
      "Ordinary" -> pure Ordinary
      "Interactive" -> pure Interactive
      _ -> fail "Unknown recipe lifetime"

-- | A task guided by instructions or implemented by an authored flow.
-- The containing fact's ID is the recipe's name.
data Recipe
  = OpenAgent { lifetime :: Lifetime, instructions :: Text }
  | ClosedAgent { lifetime :: Lifetime, flow :: FlowEntryRef }
  deriving (Eq, Show)

-- | The qualified name of an authored flow, for example Tasks.reconcile.
newtype FlowEntryRef = FlowEntryRef Text deriving (Eq, Show)
