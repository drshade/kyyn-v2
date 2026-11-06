{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Domain.Guest
  ( CheckedGuest, CheckedEntry(..), checkGuest, checkedEntries, checkedExports
  ) where

import Control.Monad (unless, forM_, void)
import Data.List (nub, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Domain.Contract
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Path (relativePath)
import qualified Kyyn.Types.Guest as G

-- Descriptions cross a process boundary. The host checks structure, annotations
-- and identity itself before exposing typed contracts to its workflows.
data CheckedGuest = CheckedGuest [CheckedEntry] [G.ExportDescription] deriving (Eq, Show)
data CheckedEntry = CheckedEntry
  { name :: Text, kind :: Text, contracts :: [(Text,CheckedContract)], capabilities :: [Text]
  } deriving (Eq, Show)

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
    ensure (exported.exportKind `elem` ["type","constructor","value","coercion"])
      "guest.exports" "Unknown export namespace"
    unless (Text.null exported.exportSource) (source exported.exportSource)
  pure (CheckedGuest entries description.exports)

checkEntry :: G.EntryDescription -> Either [Diagnostic] CheckedEntry
checkEntry entry = do
  (roles,capabilities) <- case entry.entryKind of
    "validator" -> do
      ensure (entry.entryName == "validate") "guest.entry" "Validator must use the validate entry"
      pure (["root"],[])
    "query" -> pure (["root","arguments","result"],["snapshot-read"])
    "contract" -> pure (["value"],[])
    _ -> Left [errorDiagnostic "guest.entry" "Unsupported guest entry kind"]
  ensure (sort (map fst entry.entryContracts) == sort roles) "guest.contracts" "Incorrect contracts for guest entry"
  ensure (sort entry.capabilities == sort capabilities) "guest.capabilities" "Incorrect capabilities for guest entry"
  contracts <- traverse check (entry.entryContracts)
  pure (CheckedEntry entry.entryName entry.entryKind contracts capabilities)
  where
    check (role,selected) = do
      forM_ selected.loadedSources source
      contract <- checkContract selected.structure selected.metadata
      ensure (contractFingerprint (contractId contract) == Text.unpack selected.identity)
        "guest.identity" "Guest contract fingerprint disagrees with its structure and metadata"
      if role == "root" then void (checkRootLayout contract) else pure ()
      pure (role,contract)

source :: Text -> Either [Diagnostic] ()
source path = case relativePath (Text.unpack path) of
  Left problem -> Left [errorDiagnostic "guest.source" problem]
  Right _ -> pure ()

unique :: String -> [Text] -> Either [Diagnostic] ()
unique label names = ensure (all (not . Text.null) names && length names == length (nub names))
  "guest.names" ("Guest " ++ label ++ " names must be nonempty and unique")

ensure :: Bool -> String -> String -> Either [Diagnostic] ()
ensure condition code message = unless condition (Left [errorDiagnostic code message])
