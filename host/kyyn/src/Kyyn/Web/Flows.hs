{-# LANGUAGE OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Web.Flows (flowIndex, flowPage, flowLink) where

import Control.Monad (forM_)
import Data.Aeson (Value, encode)
import qualified Data.ByteString.Lazy as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Lucid
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.FlowInstance
import Kyyn.Domain.RecipeRunId (runIdText)
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Surfaces.Flows (statusText, deliveryOutcomeText)
import Kyyn.Web.Inspection (pageDocument)

flowLink :: FlowInstanceId -> Text.Text
flowLink identity = "/flows/" <> flowInstanceIdText identity

flowIndex :: [(FlowInstance,Bool)] -> Html ()
flowIndex items = document "Interactive flows" $ do
  p_ "Durable instances and their latest activity. Refresh to see changes."
  if null items then p_ "No interactive flows started." else instanceTable items

flowPage :: FlowInstance -> Bool -> [(FlowInstance,Bool)] -> [(Text.Text,Value)] -> Html ()
flowPage item interrupted children descriptions = document (recipe item) $ do
  p_ [class_ "context"] (toHtml (flowInstanceIdText item.instanceId <> " · " <> statusText item interrupted))
  p_ $ a_ [href_ (flowLink item.instanceId)] "Refresh activity"
  forM_ item.parent $ \identity -> p_ $ do
    "Parent: "; instanceLink identity
  if item.retryRequired then p_ [class_ "diagnostic"] "Execution is blocked until an explicit retry." else mempty
  diagnostics item.blocked
  case item.status of Finished (Failed problems) -> diagnostics problems; _ -> mempty
  details_ $ do
    summary_ "Original input"
    json item.launch.request
  case item.status of
    Finished (Completed value) -> details_ $ summary_ "Result" >> json value
    _ -> mempty
  h2_ "Children"
  if null children then p_ "No child instances." else instanceTable children
  h2_ "Waits"
  if null item.waits then p_ "No waits recorded." else forM_ item.waits $ \wait -> section_ $ do
    h3_ (toHtml (waitName wait.waitStatus <> " · " <> wait.waitId))
    case wait.kind of
      ChildWait child _ -> p_ $ "Child outcome: " >> instanceLink child
      ReplyWait -> do
        p_ "Reply wait"
        forM_ (lookup wait.waitId descriptions) $ \value -> details_ $ summary_ "Request and reply contract" >> json value
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
        span_ [class_ "context"] (toHtml delivery.waitId)
      td_ (originHtml delivery.origin)
      td_ $ do
        toHtml (maybe "Queued" deliveryOutcomeText delivery.outcome)
        case delivery.outcome of Just (Invalid reason) -> p_ (toHtml reason); _ -> mempty
  h2_ "Execution attempts"
  if null item.attempts then p_ "No execution attempts yet." else ul_ $
    forM_ item.attempts $ \attempt -> li_ $
      a_ [href_ ("/runs/" <> Text.pack (runIdText attempt))] (toHtml (runIdText attempt))
  details_ $ do
    summary_ "Instance context"
    dl_ $ do
      dt_ "Execution revision"; dd_ (toHtml item.launch.revision)
      dt_ "Owner"; dd_ (case item.launch.owner of Hosted{} -> "Hosted"; External -> "External")

instanceTable :: [(FlowInstance,Bool)] -> Html ()
instanceTable items = table_ $ do
  thead_ $ tr_ $ mapM_ th_ ["Recipe / instance","Status","Parent","Open waits","Attempts"]
  tbody_ $ forM_ items $ \(item,interrupted) -> tr_ $ do
    td_ $ a_ [href_ (flowLink item.instanceId)] (toHtml (recipe item <> " · " <> flowInstanceIdText item.instanceId))
    td_ $ do
      toHtml (statusText item interrupted)
      if item.retryRequired || not (null item.blocked) then " · blocked" else mempty
    td_ $ maybe "—" instanceLink item.parent
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
originHtml :: ReplyOrigin -> Html ()
originHtml (ManualReply surface) = toHtml ("Manual · " <> surface)
originHtml (ProviderReply binding event) = toHtml ("Provider · " <> binding <> " · " <> event)
originHtml (ChildCompletion child) = "Child · " >> instanceLink child
json :: Value -> Html ()
json value = pre_ (toHtml (Text.decodeUtf8 (Bytes.toStrict (encode value))))
diagnostics :: [Diagnostic] -> Html ()
diagnostics problems = forM_ problems $ \problem -> p_ [class_ "diagnostic"] $
  toHtml (problem.code <> ": " <> problem.message)
document :: Text.Text -> Html () -> Html ()
document title = pageDocument Nothing Nothing title mempty
