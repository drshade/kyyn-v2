module Events where

import Data.Text (Text)
import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
import Kyyn.Plugin
import Kyyn.Plugin.Event
import Kyyn.Plugin.Host (PluginLogin, LoginError)
import Kyyn.Types.Diagnostic (ValidationReport(..))

data Request = Request { question :: Text } deriving stock Generic deriving anyclass Contract
data Reply = Reply { answer :: Text } deriving stock Generic deriving anyclass Contract
data Cursor = Cursor { position :: Integer } deriving stock Generic deriving anyclass Contract

connectors :: [Connector]
connectors = [EventConnector "Updates" "Events.validate" (Just "Events.login")
  [EventMethod "updates" "New updates" "Events.pollUpdates" Nothing (Seconds 1),
   EventMethod "question" "Ask a question" "Events.pollUpdates" (Just ("Events.dispatchQuestion",SafeToRepeat)) (Seconds 2)]]

validate :: Integer -> ValidationReport
validate _ = ValidationReport []

login :: Integer -> PluginLogin (Either LoginError ())
login _ = pure (Right ())

dispatchQuestion :: Integer -> EventDispatch Request -> LiveEvent (Either FetchError Cursor)
dispatchQuestion config _ = pure (Right (Cursor config))

pollUpdates :: Integer -> EventPoll Request Cursor -> LiveEvent (Either FetchError (EventBatch Reply Cursor))
pollUpdates config (EventPoll (WaitId identity) (Request question) _) =
  pure (Right (EventBatch [EventArrival (EventIdentity identity) (Reply question)] (Cursor config)))
