module Kyyn.Runtime.Entry (Entry(..), pureEntry, writeReply) where

import qualified Data.Aeson as Json
import Agentic.Aeson (fromAeson)
import Kyyn.Types.Guest (EntryDescription)
import Kyyn.Runtime.Contract (toWire)
import qualified Kyyn.Runtime.Json as Wire
import Kyyn.Runtime.Transport (Transport, writeJson)

-- Private adapters receive the invocation's existing transport. Interactive
-- entries may exchange capability requests before writing their final result.
data Entry = Entry EntryDescription (Transport -> Json.Value -> IO ())

pureEntry :: EntryDescription -> (Json.Value -> Either String Json.Value) -> Entry
pureEntry description run = Entry description $ \transport argument ->
  either fail (writeReply transport) (run argument)

writeReply :: Transport -> Json.Value -> IO ()
writeReply transport value = do
  -- Apply the same wire profile to descriptions and ordinary results.
  encoded <- either fail pure (Wire.printValue (toWire (fromAeson value)))
  writeJson transport encoded
