{-# LANGUAGE GADTs #-}
module Kyyn.Types.FlowControl (FlowControl(..)) where

import Agentic.Journal (DurableKey)
import Agentic.Value (Value)
import Data.Text (Text)
import Kyyn.Types.KnowledgeBase (RecipeId)
import Kyyn.Types.Contract (Description)
import Kyyn.Types.FlowStatus (FlowStatus, CancelScope)
import Kyyn.Types.Plugin (FetchError)

-- Only a hosted interactive broker supplies this capability.
data FlowControl a where
  StartChild :: DurableKey -> RecipeId -> Description -> Description -> Value -> FlowControl (Either FetchError Text)
  InspectChild :: Text -> Description -> FlowControl (Either FetchError (FlowStatus Value))
  CancelChild :: Text -> Description -> CancelScope -> FlowControl (Either FetchError ())
