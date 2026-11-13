{-# LANGUAGE OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Web.Runs (RunContent(..), runIndex, runPage) where

import Control.Monad (forM_)
import Data.Aeson (Value, encode)
import qualified Data.ByteString.Lazy as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Lucid
import Lucid.Base (makeAttribute)
import Network.HTTP.Types (urlEncode)
import Kyyn.Domain.Recipe (RecipeId(..))
import Kyyn.Domain.RecipeRun
import Kyyn.Domain.Evolution (evolutionIdName)
import Kyyn.Plumbing.Protocol.RecipeRun (summaryValue)

data RunContent = RunHtml (Html ()) | RunJson Value

runIndex :: Maybe RecipeId -> [RecipeRunSummary] -> Html ()
runIndex selected runs = document "Recipe runs" $ do
  p_ [class_ "muted"] "Local recordings · execution stays in the terminal"
  case selected of
    Nothing -> mempty
    Just (RecipeId name) -> p_ $ do
      toHtml ("Recipe: " <> name <> " · ")
      a_ [href_ "/runs"] "All runs"
  if null runs then p_ "No runs recorded yet." else table_ $ do
    thead_ $ tr_ $ mapM_ th_ ["Recipe / run", "Started", "Outcome", "Events", "Draft"]
    tbody_ $ forM_ runs $ \run -> tr_ $ do
      let RecipeId name = run.header.recipe
      td_ $ do
        a_ [href_ (runLink run.header.runId)] (toHtml name)
        small_ (toHtml (runIdText run.header.runId))
      td_ (toHtml run.header.startedAt)
      td_ (toHtml (status run.status))
      td_ (toHtml (show run.eventCount))
      td_ $ case run.status of
        Completed draft -> a_ [href_ ("/evolutions/" <> Text.pack (evolutionIdName draft))] (toHtml (evolutionIdName draft))
        _ -> "—"

runPage :: RecipeRunSummary -> Html ()
runPage run = document name $ do
  p_ [class_ "muted"] $ do
    toHtml (Text.pack (runIdText run.header.runId) <> " · " <> run.header.startedAt <> " · ")
    a_ [href_ ("/runs?recipe=" <> Text.decodeUtf8 (urlEncode True (Text.encodeUtf8 name)))] "Matching runs"
  textarea_ [id_ "run-data", style_ "display:none", makeAttribute "aria-hidden" "true"]
    (toHtml (Text.decodeUtf8 (Bytes.toStrict (encode (summaryValue run)))))
  div_ [id_ "run-viewer"] $ do
    p_ [id_ "run-message", role_ "status"] "Loading recorded events…"
    div_ [class_ "toolbar"] $ do
      button_ [id_ "run-follow", type_ "button"] "Follow live"
      button_ [id_ "run-play", type_ "button"] "Play"
      label_ $ do
        "Speed "
        select_ [id_ "run-speed"] $ forM_ ["0.5","1","2","5","10"] $ \speed ->
          option_ ([value_ speed] ++ [selected_ "" | speed == "1"]) (toHtml (speed <> "×"))
      button_ [id_ "run-fit", type_ "button"] "Fit diagram"
      button_ [id_ "run-zoom-in", type_ "button"] "+"
      button_ [id_ "run-zoom-out", type_ "button"] "−"
    label_ [class_ "timeline"] $ do
      "Recorded time "
      input_ [id_ "run-seek", type_ "range", min_ "0", max_ "0", step_ "1", value_ "0"]
      output_ [id_ "run-time"] "0.00 s"
    div_ [id_ "run-outcome"] mempty
    div_ [class_ "run-layout"] $ do
      section_ [class_ "diagram", id_ "run-diagram", makeAttribute "aria-label" "Recorded flow graph"] mempty
      aside_ [id_ "run-inspector"] $ do
        h2_ "Node inspector"
        p_ "Select a node to inspect its occurrences and observed progress."
    details_ $ do
      summary_ "Recording context"
      pre_ (toHtml (Text.decodeUtf8 (Bytes.toStrict (encode (summaryValue run)))))
  script_ [src_ "/_inspection/run-viewer.mjs", type_ "module"] ("" :: Text.Text)
  where RecipeId name = run.header.recipe

runLink :: RecipeRunId -> Text.Text
runLink identity = "/runs/" <> Text.pack (runIdText identity)
status :: RunStatus -> Text.Text
status Active = "Active"
status Interrupted = "Interrupted"
status (Completed _) = "Completed"
status Failed = "Failed"
status Cancelled = "Cancelled"
document :: Text.Text -> Html () -> Html ()
document title body = doctypehtml_ $ do
  head_ $ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    title_ (toHtml (title <> " · Kyyn"))
    link_ [rel_ "stylesheet", href_ "/_inspection/run-viewer.css"]
  body_ $ do
    nav_ $ do
      a_ [href_ "/"] "Knowledge base"
      a_ [href_ "/runs"] "Runs"
      a_ [href_ "/kb/"] "Views"
    h1_ (toHtml title)
    body
