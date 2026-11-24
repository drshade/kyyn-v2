{-# LANGUAGE OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Web.Flows (flowIndex, flowPage, flowLink) where

import Data.Time.Format.ISO8601 (iso8601Show)
import Control.Monad (when, forM_)
import Data.List (find)
import Data.Aeson (Value, encode)
import qualified Data.ByteString.Lazy as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Lucid
import Lucid.Base (makeAttribute)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.FlowInstance
import Kyyn.Domain.RecipeRunId (runIdText)
import Kyyn.Types.KnowledgeBase (RecipeId(..), EventReference(..))
import Kyyn.Types.EventIdentity (EventIdentity(..))
import Kyyn.Surfaces.Flows (FlowValues(..), statusText, deliveryOutcomeText, waitLabel, dispatchText)
import Kyyn.Web.Inspection (pageDocument)

flowLink :: FlowInstanceId -> Text.Text
flowLink identity = "/flows/" <> flowInstanceIdText identity

flowIndex :: [(FlowInstance,Bool)] -> Html ()
flowIndex items = document "Interactive flows" $ do
  if null items then p_ "No interactive flows started." else instanceTable True items

flowPage :: FlowInstance -> Bool -> FlowValues -> [(FlowInstance,Bool)] -> [(Text.Text,Value)] -> Html ()
flowPage item interrupted values children descriptions = document (recipe item) $ do
  section_ [id_ "flow-live"] $ do
    label_ $ do
      input_ [id_ "flow-follow", type_ "checkbox", checked_ ""]
      " Follow latest attempt"
    p_ [id_ "flow-message", role_ "status"] "Following this conversation."
    iframe_ [id_ "flow-run", title_ "Conversation execution", style_ "width:100%;height:75vh;border:1px solid #ddd", makeAttribute "hidden" ""] mempty
  div_ [id_ "flow-snapshot"] (snapshot item interrupted values children descriptions)
  script_ [src_ "/_inspection/flow-viewer.mjs", type_ "module"] ("" :: Text.Text)

snapshot :: FlowInstance -> Bool -> FlowValues -> [(FlowInstance,Bool)] -> [(Text.Text,Value)] -> Html ()
snapshot item interrupted values children descriptions = do
  p_ [class_ "context"] (toHtml (flowInstanceIdText item.instanceId <> " · " <> statusText item interrupted))
  forM_ item.parent $ \identity -> p_ $ do
    "Parent: "; instanceLink identity
  if item.retryRequired then p_ [class_ "diagnostic"] "Execution is blocked until an explicit retry." else mempty
  diagnostics item.blocked
  case item.status of Finished (Failed problems) -> diagnostics problems; _ -> mempty
  diagnostics values.diagnostics
  forM_ values.input $ \value -> details_ $ summary_ "Original input" >> pre_ (toHtml value)
  forM_ values.output $ \value -> details_ $ summary_ "Result" >> pre_ (toHtml value)
  h2_ "Children"
  if null children then p_ "No child instances." else instanceTable False children
  h2_ "Waits"
  if null item.waits then p_ "No waits recorded." else forM_ (zip [1..] item.waits) $ \(index,wait) -> section_ [makeAttribute "data-wait" wait.waitId] $ do
    h3_ (toHtml (waitLabel index descriptions wait <> " · " <> waitName wait.waitStatus))
    details_ $ summary_ "Wait identity" >> code_ (toHtml wait.waitId)
    case wait.kind of
      ChildWait child _ -> p_ $ "Child outcome: " >> instanceLink child
      _ -> do
        forM_ (lookup wait.waitId descriptions) $ \value -> details_ $ summary_ "Request and reply contract" >> json value
    forM_ wait.adapter $ \state -> do
      p_ (toHtml ("Dispatch: " <> dispatchText state.dispatch))
      diagnostics state.dispatchProblems
      mapM_ (\time -> p_ (toHtml ("Last poll: " ++ iso8601Show time))) state.polling.lastAttempt
      mapM_ (\time -> p_ (toHtml ("Next poll: " ++ iso8601Show time))) state.polling.nextAttempt
      when (state.polling.consecutiveFailures > 0) $ p_ (toHtml ("Consecutive poll failures: " ++ show state.polling.consecutiveFailures))
      diagnostics state.polling.problems
      forM_ state.cursor $ \value -> details_ $ summary_ "Adapter cursor" >> json value
    case wait.waitStatus of
      Answered origin value -> do
        p_ $ "Received from: " >> originHtml origin
        details_ $ summary_ "Accepted reply" >> json value
      _ -> mempty
  h2_ "Deliveries"
  if null item.deliveries then p_ "No deliveries received." else table_ $ do
    thead_ $ tr_ $ mapM_ th_ ["Delivery / wait","Origin","Outcome"]
    tbody_ $ forM_ item.deliveries $ \delivery -> tr_ $ do
      td_ $ do
        toHtml delivery.deliveryId
        br_ []
        let label = case find ((== delivery.waitId) . (.waitId) . snd) (zip [1..] item.waits) of
              Just (index,wait) -> waitLabel index descriptions wait
              Nothing -> delivery.waitId
        span_ [class_ "context"] (toHtml label)
      td_ (originHtml delivery.origin)
      td_ $ do
        toHtml (maybe "Queued" deliveryOutcomeText delivery.outcome)
        case delivery.outcome of Just (Invalid reason) -> p_ (toHtml reason); _ -> mempty
  h2_ "Execution attempts"
  if null item.attempts then p_ "No execution attempts yet." else ul_ $
    forM_ item.attempts $ \attempt -> li_ $
      a_ [makeAttribute "data-attempt" (Text.pack (runIdText attempt)), href_ ("/runs/" <> Text.pack (runIdText attempt))] (toHtml (runIdText attempt))
  details_ $ do
    summary_ "Instance context"
    dl_ $ do
      dt_ "Execution revision"; dd_ (toHtml item.launch.revision)
      dt_ "Owner"; dd_ (case item.launch.owner of Hosted{} -> "Hosted"; External -> "External")

instanceTable :: Bool -> [(FlowInstance,Bool)] -> Html ()
instanceTable showParent items = table_ $ do
  thead_ $ tr_ $ mapM_ th_ (["Recipe / instance","Status"] ++ ["Parent" | showParent] ++ ["Open waits","Attempts"])
  tbody_ $ forM_ items $ \(item,interrupted) -> tr_ $ do
    td_ $ a_ [href_ (flowLink item.instanceId)] (toHtml (recipe item <> " · " <> flowInstanceIdText item.instanceId))
    td_ $ do
      toHtml (statusText item interrupted)
      if item.retryRequired || not (null item.blocked) then " · blocked" else mempty
    if showParent then td_ (maybe "—" instanceLink item.parent) else mempty
    td_ (toHtml (show (length [wait | wait <- item.waits, wait.waitStatus == Open])))
    td_ (toHtml (show (length item.attempts)))

recipe :: FlowInstance -> Text.Text
recipe item = case item.launch.owner of Hosted _ (RecipeId name) -> name; External -> "External flow"
instanceLink :: FlowInstanceId -> Html ()
instanceLink identity = a_ [href_ (flowLink identity)] (toHtml (flowInstanceIdText identity))
waitName :: WaitStatus -> Text.Text
waitName Open = "Open"
waitName Answered{} = "Answered"
waitName Closed = "Closed"
originHtml :: DeliveryOrigin -> Html ()
originHtml (ReceivedFrom (ManualReply surface)) = toHtml ("Manual · " <> surface)
originHtml (ReceivedFrom (ProviderReply binding (EventIdentity event))) = toHtml ("Provider · " <> binding.plugin <> "/" <> binding.instanceName <> "/" <> binding.method <> " · " <> event)
originHtml (ChildCompletion child) = "Child · " >> instanceLink child
json :: Value -> Html ()
json value = pre_ (toHtml (Text.decodeUtf8 (Bytes.toStrict (encode value))))
diagnostics :: [Diagnostic] -> Html ()
diagnostics problems = forM_ problems $ \problem -> p_ [class_ "diagnostic"] $
  toHtml (problem.code <> ": " <> problem.message)
document :: Text.Text -> Html () -> Html ()
document title = pageDocument Nothing Nothing title mempty
