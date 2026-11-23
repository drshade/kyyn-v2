{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.KnowledgeBase (Lifetime(..), InteractionBindings(..), ChildReference(..), Recipe(..), RecipeId(..), FlowEntryRef(..)) where

import Data.Text (Text)
import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), object, withObject, (.=), (.:))
import Kyyn.Types.Json (exactObject)

-- | The name of an identified recipe in the selected root.
newtype RecipeId = RecipeId Text deriving (Eq, Show)

-- | Captured authority comes from the recipe declaration, never model output.
data InteractionBindings = InteractionBindings { children :: [ChildReference] }
  deriving (Eq, Show)
data ChildReference = ChildReference RecipeId FlowEntryRef deriving (Eq, Show)
instance ToJSON ChildReference where
  toJSON (ChildReference (RecipeId ident) (FlowEntryRef entry)) =
    object ["recipe" .= ident, "flow" .= entry]
instance FromJSON ChildReference where
  parseJSON = exactObject "child flow reference" ["recipe","flow"] $ \fields ->
    ChildReference <$> (RecipeId <$> fields .: "recipe") <*> (FlowEntryRef <$> fields .: "flow")
instance ToJSON InteractionBindings where
  toJSON (InteractionBindings refs) = object ["children" .= refs]
instance FromJSON InteractionBindings where
  parseJSON = exactObject "interactive bindings" ["children"] $ \fields ->
    InteractionBindings <$> fields .: "children"

data Lifetime = Ordinary | Interactive InteractionBindings deriving (Eq, Show)
instance ToJSON Lifetime where
  toJSON Ordinary = object ["tag" .= String "Ordinary"]
  toJSON (Interactive bindings) = object ["tag" .= String "Interactive", "value" .= bindings]
instance FromJSON Lifetime where
  parseJSON value = do
    tag <- withObject "recipe lifetime" (.: "tag") value
    case tag :: Text of
      "Ordinary" -> exactObject "ordinary lifetime" ["tag"] (const (pure Ordinary)) value
      "Interactive" -> exactObject "interactive lifetime" ["tag","value"]
        (\fields -> Interactive <$> fields .: "value") value
      _ -> fail "Unknown recipe lifetime"

-- | A task guided by instructions or implemented by an authored flow.
-- The containing fact's ID is the recipe's name.
data Recipe
  = OpenAgent { lifetime :: Lifetime, instructions :: Text }
  | ClosedAgent { lifetime :: Lifetime, flow :: FlowEntryRef }
  deriving (Eq, Show)

-- | The qualified name of an authored flow, for example Tasks.reconcile.
newtype FlowEntryRef = FlowEntryRef Text deriving (Eq, Show)
