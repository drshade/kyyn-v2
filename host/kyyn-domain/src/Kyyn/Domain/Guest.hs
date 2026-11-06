{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Domain.Guest
  ( CheckedGuest, CheckedEntry, InspectedSchema(..), checkGuest, checkedEntries, checkedExports
  ) where

import Control.Monad (unless, forM_, void)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Domain.Contract
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Path (RelativePath, relativePath)
import qualified Kyyn.Types.Guest as G

-- Descriptions cross a process boundary. The host checks structure, annotations
-- and identity itself before exposing typed contracts to its workflows.
data CheckedGuest = CheckedGuest [CheckedEntry] [G.ExportDescription] deriving (Eq, Show)
data InspectedSchema = InspectedSchema
  { contract :: CheckedContract, loadedSources :: [RelativePath] } deriving (Eq, Show)
type CheckedEntry = G.GuestEntry InspectedSchema

checkedEntries :: CheckedGuest -> [CheckedEntry]
checkedEntries (CheckedGuest entries _) = entries

checkedExports :: CheckedGuest -> [G.ExportDescription]
checkedExports (CheckedGuest _ exports) = exports

checkGuest :: G.GuestDescription -> Either [Diagnostic] CheckedGuest
checkGuest description = do
  ensure (description.protocol == G.protocolIdentity) "guest.protocol" "Unrecognized guest protocol"
  unique "entry" (map G.entryName description.entries)
  entries <- traverse checkEntry description.entries
  let symbols = [(e.exportModule,e.exportName,e.exportKind) | e <- description.exports]
  ensure (length symbols == length (nub symbols)) "guest.exports" "Duplicate exported symbol"
  forM_ description.exports $ \exported -> do
    ensure (all (not . Text.null) [exported.exportModule,exported.exportName,exported.exportSignature])
      "guest.exports" "Incomplete exported symbol"
    unless (Text.null exported.exportSource) (void (source exported.exportSource))
  pure (CheckedGuest entries description.exports)

checkEntry :: G.EntryDescription -> Either [Diagnostic] CheckedEntry
checkEntry entry = case entry of
  G.ValidatorEntry name selected -> do
    ensure (name == "validate") "guest.entry" "Validator must use the validate entry"
    G.ValidatorEntry name <$> root selected
  G.QueryEntry name (G.QueryContracts rootContract arguments result) ->
    G.QueryEntry name <$> (G.QueryContracts <$> root rootContract <*> check arguments <*> check result)
  G.ContractEntry name selected -> G.ContractEntry name <$> check selected
  where
    root selected = do
      inspected <- check selected
      void (checkRootLayout inspected.contract)
      pure inspected
    check selected = do
      sources <- traverse source selected.loadedSources
      contract <- checkContract selected.structure selected.metadata
      ensure (contractFingerprint (contractId contract) == Text.unpack selected.identity)
        "guest.identity" "Guest contract fingerprint disagrees with its structure and metadata"
      pure (InspectedSchema contract sources)

source :: Text -> Either [Diagnostic] RelativePath
source path = case relativePath (Text.unpack path) of
  Left problem -> Left [errorDiagnostic "guest.source" problem]
  Right selectedPath -> pure selectedPath

unique :: String -> [Text] -> Either [Diagnostic] ()
unique label names = ensure (all (not . Text.null) names && length names == length (nub names))
  "guest.names" ("Guest " ++ label ++ " names must be nonempty and unique")

ensure :: Bool -> String -> String -> Either [Diagnostic] ()
ensure condition code message = unless condition (Left [errorDiagnostic code message])
