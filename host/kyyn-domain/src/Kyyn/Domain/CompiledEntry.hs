module Kyyn.Domain.CompiledEntry
  ( CompiledEntry, compiledEntries, entryProgram, entryDescription ) where

import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Guest (CheckedGuest, CheckedEntry, checkedEntries)
import Kyyn.Types.Guest (GuestEntry(..))

-- A broker receives an entry from a checked description, never a free-text
-- operation name. Every selected entry retains the same immutable executable.
data CompiledEntry = CompiledEntry CompiledProgram CheckedEntry deriving (Eq, Show)

compiledEntries :: CompiledProgram -> CheckedGuest -> [CompiledEntry]
compiledEntries program guest = [CompiledEntry program entry | entry <- checkedEntries guest, runnable entry]
  where
    runnable ContractEntry{} = False
    runnable _ = True

entryProgram :: CompiledEntry -> CompiledProgram
entryProgram (CompiledEntry program _) = program

entryDescription :: CompiledEntry -> CheckedEntry
entryDescription (CompiledEntry _ description) = description
