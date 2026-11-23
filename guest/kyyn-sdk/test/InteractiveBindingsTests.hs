{-# LANGUAGE OverloadedStrings #-}
module InteractiveBindingsTests (main) where

import Control.Monad (unless)
import Data.Text (Text)
import Kyyn.Interactive
import Kyyn.Interactive.Internal (FlowDefinition(..))
import Kyyn.Interactive.Event (EventRef(..), eventRef)
import Kyyn.Plugin.Event (LiveEvent, EventPoll, EventBatch)
import Kyyn.Types.Plugin (ConnectorInstance(..), FetchError)
import Kyyn.Types.KnowledgeBase

main :: IO ()
main = do
  let base = FlowDefinition (FlowEntryRef "Flows.parent") (InteractionBindings [] [])
        (error "state must not be forced") (error "input must not be forced") (error "output must not be forced") :: FlowDefinition () ()
      reference = eventRef "fixture" "Updates" "question" poll (ConnectorInstance "updates" :: ConnectorInstance ())
      EventRef expected _ = reference
      childRef = child (RecipeId "child") base
      bindings (FlowDefinition _ selected _ _ _) = selected
      left = bindings (withChildren [childRef] (withEvents [event reference] base))
      right = bindings (withEvents [event reference] (withChildren [childRef] base))
  unless (left == right && left == InteractionBindings [ChildReference (RecipeId "child") (FlowEntryRef "Flows.parent")] [expected])
    (fail "Child and event declaration helpers do not preserve one another")
  unless (bindings (withEvents [] (withChildren [childRef] base)) == InteractionBindings [ChildReference (RecipeId "child") (FlowEntryRef "Flows.parent")] [])
    (fail "Replacing events cleared child declarations")
  putStrLn "Event type witnesses stay unevaluated and declaration helpers compose."
  where
    poll :: () -> EventPoll Text Integer -> LiveEvent (Either FetchError (EventBatch Text Integer))
    poll = error "The poll type witness must not run during declaration"
