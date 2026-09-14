module Kyyn.Plumbing.Protocol.PluginInvocation (acquisitionSources, capturedReadSources) where

import qualified Data.ByteString as Bytes
import Data.List (nub)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.DataType (DataType(..), haskellType, definingModule, reachableTypes)
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources, bindingModule)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

acquisitionSources :: DataType -> DataType -> String -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
acquisitionSources config payload = sources config payload Nothing

capturedReadSources :: DataType -> DataType -> DataType -> String
  -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
capturedReadSources arguments payload result = sources arguments payload (Just result)

sources :: DataType -> DataType -> Maybe DataType -> String
  -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
sources arguments payload result implementation authored = do
  implementationModule <- bindingModule implementation
  codecs <- traverse (\(name,datatype) -> do
    path <- relativePath (name ++ ".hs")
    body <- generateCodecs name datatype
    pure (path,utf8 body))
    ([("KyynPluginArgumentsCodec",arguments),("KyynPluginPayloadCodec",payload)] ++
      [("KyynPluginResultCodec",r) | Just r <- [result]])
  entryPath <- relativePath "KyynPluginEntry.hs"
  bindingsPath <- relativePath "KyynPluginBindings.hs"
  let mode = case result of Nothing -> "Acquisition"; Just _ -> "CapturedRead"
      resultType = case result of Nothing -> "[SDK.EvidenceChange " ++ haskellType payload ++ "]"; Just r -> haskellType r
      runtime = case result of
        Nothing -> "executeAcquisition Arguments.rootCodec Payload.rootCodec selected"
        Just _ -> "executeCapturedRead Arguments.rootCodec Payload.rootCodec Result.rootCodec selected"
      entry = unlines $ ["module KyynPluginEntry where","import qualified " ++ implementationModule,
        "import qualified Kyyn.Plugin as SDK","import qualified KyynPluginBindings as Bindings",
        "import qualified KyynPluginArgumentsCodec as Arguments","import qualified KyynPluginPayloadCodec as Payload",
        "import Kyyn.Runtime.Plugin"] ++ imports (arguments:payload:maybe [] pure result) ++
        ["import qualified KyynPluginResultCodec as Result" | Just _ <- [result]] ++
        ["selected :: " ++ haskellType arguments ++ " -> SDK.EvidenceSnapshot " ++ haskellType payload ++
          " -> Bindings." ++ mode ++ " (Either SDK.FetchError " ++ resultType ++ ")",
         "selected = " ++ implementation,"main :: IO ()","main = " ++ runtime]
      bindings = unlines $ ["{-# LANGUAGE TypeOperators #-}",
        "module KyynPluginBindings (Program, EvidenceSnapshot, FetchError(..), EvidenceId(..), Evidence(..), EvidenceChange(..), " ++ mode ++ ", listEvidenceIds, readEvidence" ++
          (case result of Nothing -> ", listFiles, readTextFile"; Just _ -> "") ++ ") where",
        "import Kyyn.Plugin","import qualified Kyyn.Types.Program as P","import qualified Kyyn.Types.Plugin as Calls"] ++
        imports [payload] ++
        ["type " ++ mode ++ " a = Program " ++ (case result of
          Nothing -> "(Calls.FileRead P.:+: Calls.EvidenceRead " ++ haskellType payload ++ ")"
          Just _ -> "(Calls.EvidenceRead " ++ haskellType payload ++ ")") ++ " a",
         "listEvidenceIds :: EvidenceSnapshot " ++ haskellType payload ++ " -> " ++ mode ++ " (Either FetchError [EvidenceId])",
         "listEvidenceIds snapshot = " ++ inject "Calls.ListEvidenceIds snapshot",
         "readEvidence :: EvidenceSnapshot " ++ haskellType payload ++ " -> EvidenceId -> " ++ mode ++
           " (Either FetchError (Maybe (Evidence " ++ haskellType payload ++ ")))",
         "readEvidence snapshot key = " ++ inject "Calls.ReadEvidence snapshot key"] ++
        (case result of
          Nothing -> ["listFiles :: FilePath -> Bool -> Acquisition (Either FetchError [FilePath])",
            "listFiles directory recursive = P.request (P.InLeft (Calls.ListFiles directory recursive))",
            "readTextFile :: FilePath -> Acquisition (Either FetchError String)",
            "readTextFile path = P.request (P.InLeft (Calls.ReadTextFile path))"]
          Just _ -> [])
      inject operation = "P.request (" ++ (case result of Nothing -> "P.InRight (" ++ operation ++ ")"; Just _ -> operation) ++ ")"
  guestSources entryPath (authored ++ codecs ++ [(entryPath,utf8 entry),(bindingsPath,utf8 bindings)])

imports :: [DataType] -> [String]
imports datatypes = ["import qualified " ++ name | name <- nub
  [definingModule name | datatype <- datatypes, Algebraic name _ _ <- reachableTypes datatype]]

utf8 :: String -> Bytes.ByteString
utf8 = Text.encodeUtf8 . Text.pack
