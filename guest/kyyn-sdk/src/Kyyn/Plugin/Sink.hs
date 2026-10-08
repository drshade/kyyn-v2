module Kyyn.Plugin.Sink (Sink, SinkError(..), writeTextFile) where

import Data.Text (Text)
import Kyyn.Types.Program (Program, request)
import Kyyn.Types.Sink

-- | A plugin sink program. Publishing, not querying, installs these capabilities.
type Sink a = Program SinkCalls a

-- | Write UTF-8 text, creating parents and atomically replacing the destination.
-- Relative paths are relative to the KB. Returns the absolute destination.
writeTextFile :: FilePath -> Text -> Sink (Either SinkError FilePath)
writeTextFile path = request . WriteTextFile path
