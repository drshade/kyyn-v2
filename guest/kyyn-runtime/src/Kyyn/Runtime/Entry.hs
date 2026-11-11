module Kyyn.Runtime.Entry (Entry(..), Adapter(..), CapturedAdapter(..), pureAdapter, pureEntry, writeReply, entryActions, entryDescriptor) where

import qualified Data.Aeson as Json
import Agentic.Aeson (fromAeson)
import Data.Text (Text)
import Kyyn.Types.Guest (EntryDescription, Invocation(..), DescribedContract, CapturedContracts, entryNames)
import Kyyn.Runtime.Contract (toWire)
import qualified Kyyn.Runtime.Json as Wire
import Kyyn.Runtime.Transport (Transport, writeJson)

-- Private adapters receive the invocation's existing transport. Interactive
-- entries may exchange capability requests before writing their final result.
type Action = Transport -> Json.Value -> IO ()
data Entry = Entry EntryDescription Action | DescriptionEntry EntryDescription | ConnectorGroup EntryDescription [(Text,Action)]
data Adapter contract = Adapter (Invocation contract) Action
data CapturedAdapter = CapturedAdapter Text Text (Adapter (CapturedContracts DescribedContract))

pureAdapter :: Invocation contract -> (Json.Value -> Either String Json.Value) -> Adapter contract
pureAdapter description run = Adapter description $ \transport argument ->
  either fail (writeReply transport) (run argument)

entryDescriptor :: Entry -> EntryDescription
entryDescriptor (Entry description _) = description
entryDescriptor (DescriptionEntry description) = description
entryDescriptor (ConnectorGroup description _) = description

entryActions :: Entry -> [(Text,Action)]
entryActions (DescriptionEntry _) = []
entryActions (Entry description run) = case entryNames description of
  [name] -> [(name,run)]
  _ -> error "A single-entry adapter requires exactly one invocation name"
entryActions (ConnectorGroup _ actions) = actions

pureEntry :: EntryDescription -> (Json.Value -> Either String Json.Value) -> Entry
pureEntry description run = Entry description $ \transport argument ->
  either fail (writeReply transport) (run argument)

writeReply :: Transport -> Json.Value -> IO ()
writeReply transport value = do
  -- Apply the same wire profile to descriptions and ordinary results.
  encoded <- either fail pure (Wire.printValue (toWire (fromAeson value)))
  writeJson transport encoded
