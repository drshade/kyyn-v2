-- | Render the derived model into one self-contained HTML page: the embedded
-- template with the data inlined. No network, git or file access beyond the output.
{-# LANGUAGE OverloadedStrings #-}
module AdrViewer.Render (renderPage, renderData) where

import AdrViewer.Check (Inputs(..))
import AdrViewer.Json (encodeCompact)
import AdrViewer.Model
import AdrViewer.Template (viewerTemplate)
import AdrViewer.Types
import Data.Aeson (Value(..), object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as K
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

placeholder :: T.Text
placeholder = "/*ADR_VIEWER_DATA*/null"

renderPage :: Inputs -> BL.ByteString
renderPage inputs = case T.breakOn placeholder template of
  (before, after) | not (T.null after) ->
    BL.fromStrict (TE.encodeUtf8 (before <> json <> T.drop (T.length placeholder) after))
  _ -> error "viewer template has no data placeholder"
  where
    template = T.pack viewerTemplate
    -- Inline safely inside <script>: no "</" can close the element early.
    json = T.replace "</" "<\\/" (TE.decodeUtf8 (BL.toStrict (encodeCompact (renderData inputs))))

renderData :: Inputs -> Value
renderData inputs = object
  [ "name" .= repoName (inRepo inputs), "repoUrl" .= repoUrl (inRepo inputs), "maxSeq" .= maxSeq
  , "steps" .= [ object ["seq" .= stepSeq s, "date" .= stepDate s, "pr" .= stepPr s, "title" .= stepTitle s, "adrs" .= stepAdrs s]
               | s <- inSteps inputs ]
  , "adrs" .= inAdrs inputs
  , "lanes" .= object [K.fromText (laneAdr (lvLane v)) .= laneJson v | v <- views]
  , "convergence" .= convergence views ]
  where
    maxSeq = if null (inSteps inputs) then 0 else maximum (map stepSeq (inSteps inputs))
    views = [laneView maxSeq lane | (_, lane) <- inLanes inputs]

laneJson :: LaneView -> Value
laneJson v = object
  [ "adr" .= laneAdr lane, "title" .= laneTitle lane, "cursor" .= laneCursor lane, "notes" .= laneNotes lane
  , "editorialCount" .= length (laneEditorial lane), "depth" .= lvDepth v
  , "counts" .= [[d, p] | (d, p) <- lvCounts v]
  , "nodes" .= map nodeJson (lvNodes v) ]
  where lane = lvLane v

nodeJson :: NodeView -> Value
nodeJson v = case toJSON (nvNode v) of
  Object o -> Object (KM.insert "until" (toJSON (nvUntil v)) (KM.insert "realisedAt" (toJSON (nvRealisedAt v))
                (KM.insert "track" (toJSON (nvTrack v)) o)))
  other -> other
