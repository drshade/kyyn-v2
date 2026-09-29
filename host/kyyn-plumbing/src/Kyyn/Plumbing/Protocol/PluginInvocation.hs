module Kyyn.Plumbing.Protocol.PluginInvocation (acquisitionSources, capturedReadSources, loginSources) where

import qualified Data.ByteString as Bytes
import Data.List (nub)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.DataType (DataType(..), haskellType, definingModule, reachableTypes)
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources, bindingModule)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

acquisitionSources :: DataType -> DataType -> Maybe DataType -> String -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
acquisitionSources config payload options = sources config payload Nothing options

capturedReadSources :: DataType -> DataType -> DataType -> String
  -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
capturedReadSources arguments payload result = sources arguments payload (Just result) Nothing

sources :: DataType -> DataType -> Maybe DataType -> Maybe DataType -> String
  -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
sources arguments payload result options implementation authored = do
  implementationModule <- bindingModule implementation
  codecs <- traverse (\(name,datatype) -> do
    path <- relativePath (name ++ ".hs")
    body <- generateCodecs name datatype
    pure (path,utf8 body))
    ([("KyynPluginArgumentsCodec",arguments),("KyynPluginPayloadCodec",payload)] ++
      [("KyynPluginResultCodec",r) | Just r <- [result]] ++
      [("KyynPluginOptionsCodec",o) | Just o <- [options]])
  entryPath <- relativePath "KyynPluginEntry.hs"
  bindingsPath <- relativePath "KyynPluginBindings.hs"
  let mode = case result of Nothing -> "Acquisition"; Just _ -> "CapturedRead"
      resultType = case result of Nothing -> "[SDK.EvidenceChange " ++ haskellType payload ++ "]"; Just r -> haskellType r
      runtime = case result of
        Nothing -> case options of
          Nothing -> "executeAcquisition Arguments.rootCodec Payload.rootCodec selected"
          Just _ -> "executeAcquisition (withOptionsCodec Arguments.rootCodec Options.rootCodec) Payload.rootCodec (uncurry selected)"
        Just _ -> "executeCapturedRead Arguments.rootCodec Payload.rootCodec Result.rootCodec selected"
      entry = unlines $ ["module KyynPluginEntry where","import qualified " ++ implementationModule,
        "import qualified Kyyn.Plugin as SDK","import qualified KyynPluginBindings as Bindings",
        "import qualified KyynPluginArgumentsCodec as Arguments","import qualified KyynPluginPayloadCodec as Payload",
        "import Kyyn.Runtime.Plugin","import Kyyn.Runtime.PluginHost"] ++ imports (arguments:payload:maybe [] pure result ++ maybe [] pure options) ++
        ["import qualified KyynPluginOptionsCodec as Options" | Just _ <- [options]] ++
        ["import qualified KyynPluginResultCodec as Result" | Just _ <- [result]] ++
        ["selected :: " ++ haskellType arguments ++ maybe "" (\o -> " -> Maybe (" ++ haskellType o ++ ")") options ++ " -> SDK.EvidenceSnapshot " ++ haskellType payload ++
          " -> Bindings." ++ mode ++ " (Either SDK.FetchError " ++ resultType ++ ")",
         "selected = " ++ implementation,"main :: IO ()","main = " ++ runtime]
      bindings = unlines $ ["{-# LANGUAGE TypeOperators, DuplicateRecordFields #-}",
        "module KyynPluginBindings (Program, EvidenceSnapshot, FetchError(..), EvidenceId(..), EvidenceFingerprint(..), Evidence(..), EvidenceChange(..), " ++ mode ++ ", listEvidenceIds, readEvidence" ++
          (case result of Nothing -> ", HttpRequest(..), HttpResponse(..), HttpError(..), SecretError(..), sendHttp, getSecret, putSecret, waitSeconds, CapturedText(..), listFiles, readTextFile"; Just _ -> "") ++ ") where",
        "import Kyyn.Plugin","import qualified Kyyn.Types.Program as P","import qualified Kyyn.Types.Plugin as Calls"] ++
        ["import Kyyn.Plugin.Host hiding (Acquisition)","import qualified Kyyn.Plugin.Host as Host"] ++
        imports [payload] ++
        ["type " ++ mode ++ " a = " ++ (case result of
          Nothing -> "Host.Acquisition " ++ haskellType payload
          Just _ -> "Program (Calls.EvidenceRead " ++ haskellType payload ++ ")") ++ " a",
         "listEvidenceIds :: EvidenceSnapshot " ++ haskellType payload ++ " -> " ++ mode ++ " (Either FetchError [EvidenceId])",
         "listEvidenceIds snapshot = " ++ inject "Calls.ListEvidenceIds snapshot",
         "readEvidence :: EvidenceSnapshot " ++ haskellType payload ++ " -> EvidenceId -> " ++ mode ++
           " (Either FetchError (Maybe (Evidence " ++ haskellType payload ++ ")))",
         "readEvidence snapshot key = " ++ inject "Calls.ReadEvidence snapshot key"] ++
        (case result of
          Nothing -> ["listFiles :: FilePath -> Bool -> Acquisition (Either FetchError [FilePath])",
            "listFiles directory recursive = P.request (P.InRight (P.InRight (P.InRight (P.InLeft (Calls.ListFiles directory recursive)))))",
            "readTextFile :: FilePath -> Acquisition (Either FetchError CapturedText)",
            "readTextFile path = P.request (P.InRight (P.InRight (P.InRight (P.InLeft (Calls.ReadTextFile path)))))"]
          _ -> [])
      inject operation = "P.request (" ++ (case result of
        Nothing -> "P.InRight (P.InRight (P.InRight (P.InRight (" ++ operation ++ "))))"
        Just _ -> operation) ++ ")"
  guestSources entryPath (authored ++ codecs ++ [(entryPath,utf8 entry),(bindingsPath,utf8 bindings)])

loginSources :: DataType -> String -> [(RelativePath,Bytes.ByteString)] -> Either String GuestSources
loginSources config implementation authored = do
  selectedModule <- bindingModule implementation
  entryPath <- relativePath "KyynPluginLoginEntry.hs"
  codecPath <- relativePath "KyynPluginLoginCodec.hs"
  codec <- generateCodecs "KyynPluginLoginCodec" config
  let entry = unlines $ ["module KyynPluginLoginEntry where","import qualified " ++ selectedModule,
        "import Kyyn.Plugin.Host","import Kyyn.Runtime.PluginHost (executeLogin)",
        "import qualified KyynPluginLoginCodec as Codec"] ++ imports [config] ++
        ["selected :: " ++ haskellType config ++ " -> PluginLogin (Either LoginError ())",
         "selected = " ++ implementation,"main :: IO ()","main = executeLogin Codec.rootCodec selected"]
  guestSources entryPath (authored ++ [(entryPath,utf8 entry),(codecPath,utf8 codec)])

imports :: [DataType] -> [String]
imports datatypes = ["import qualified " ++ name | name <- nub
  [definingModule name | datatype <- datatypes, Algebraic name _ _ <- reachableTypes datatype]]

utf8 :: String -> Bytes.ByteString
utf8 = Text.encodeUtf8 . Text.pack
