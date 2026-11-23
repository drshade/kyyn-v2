module Kyyn.Types.EventIdentity (EventIdentity(..)) where

import Data.Text (Text)
import Agentic.Contract (Contract(..), Structure, nominal, mapStructure)

-- Provider-assigned stable identity; distinct from a binding or wait identity.
newtype EventIdentity = EventIdentity Text deriving (Eq, Show)
instance Contract EventIdentity where
  contract = nominal (mapStructure EventIdentity (\(EventIdentity value) -> value) (contract :: Structure Text))
