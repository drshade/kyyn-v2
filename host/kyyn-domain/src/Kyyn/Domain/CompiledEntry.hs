{-# LANGUAGE OverloadedRecordDot #-}
module Kyyn.Domain.CompiledEntry
  ( CompiledEntry, CompiledConnector(..), compiledEntries, compiledConnectors, entryProgram, entryDescription, invocationName ) where

import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Guest (CheckedGuest, CheckedEntry, InspectedSchema, checkedEntries)
import Data.Text (Text)
import qualified Kyyn.Types.Guest as G
import Kyyn.Types.Guest (GuestEntry(..))

-- A broker receives an entry from a checked description, never a free-text
-- operation name. Every selected entry retains the same immutable executable.
data CompiledEntry = CompiledEntry CompiledProgram CheckedEntry Text deriving (Eq, Show)

compiledEntries :: CompiledProgram -> CheckedGuest -> [CompiledEntry]
compiledEntries program guest = [CompiledEntry program entry (G.entryName entry) | entry <- checkedEntries guest, runnable entry]
  where
    runnable ConnectorEntry{} = False
    runnable ContractEntry{} = False
    runnable EvolutionDescriptionEntry{} = False
    runnable _ = True

entryProgram :: CompiledEntry -> CompiledProgram
entryProgram (CompiledEntry program _ _) = program

entryDescription :: CompiledEntry -> CheckedEntry
entryDescription (CompiledEntry _ description _) = description

invocationName :: CompiledEntry -> Text
invocationName (CompiledEntry _ _ name) = name

-- Keep the checked connector structure when attaching the executable. A caller
-- never reconstructs its roles or supplies a free-text dispatch target.
data CompiledConnector
  = CompiledSource G.ConnectorIdentity (G.AcquisitionContracts InspectedSchema)
      CompiledEntry CompiledEntry (Maybe CompiledEntry) [(G.CapturedEntry InspectedSchema,CompiledEntry)]
  | CompiledSink G.ConnectorIdentity (G.SinkContracts InspectedSchema)
      CompiledEntry CompiledEntry CompiledEntry
  deriving (Eq, Show)

compiledConnectors :: CompiledProgram -> CheckedGuest -> [CompiledConnector]
compiledConnectors program guest = [attach entry identity selected |
  entry@(ConnectorEntry identity selected) <- checkedEntries guest]
  where
    attach entry identity selected =
      let handle invocation = CompiledEntry program entry (G.invocationName invocation)
      in case selected of
        G.SourceEntries config acquisition login methods ->
          CompiledSource identity acquisition.invocationContract (handle acquisition) (handle config)
            (handle <$> login) [(method,handle method.capturedInvocation) | method <- methods]
        G.SinkEntries config publication defaults ->
          CompiledSink identity publication.invocationContract (handle publication) (handle config) (handle defaults)
