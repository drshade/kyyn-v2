module Kyyn.Plumbing.Protocol.PluginInvocation (acquisitionSources, statefulAcquisitionSources, capturedReadSources, loginSources) where

import qualified Data.ByteString as Bytes
import Data.List (nub)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.DataType (DataType(..), haskellType, typeModules)
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources, bindingModule)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

acquisitionSources :: DataType -> DataType -> Maybe DataType -> String -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
acquisitionSources config payload options = sources config payload Nothing options Nothing

statefulAcquisitionSources :: DataType -> DataType -> Maybe DataType -> DataType -> String
  -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
statefulAcquisitionSources config payload options position = sources config payload Nothing options (Just position)

capturedReadSources :: DataType -> DataType -> DataType -> String
  -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
capturedReadSources arguments payload result = sources arguments payload (Just result) Nothing Nothing

sources :: DataType -> DataType -> Maybe DataType -> Maybe DataType -> Maybe DataType -> String
  -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
sources arguments payload result options position implementation authored = do
  implementationModule <- bindingModule implementation
  codecs <- traverse (\(name,datatype) -> do
    path <- relativePath (name ++ ".hs")
    body <- generateCodecs name datatype
    pure (path,utf8 body))
    ([("KyynPluginArgumentsCodec",arguments),("KyynPluginPayloadCodec",payload)] ++
      [("KyynPluginResultCodec",r) | Just r <- [result]] ++
      [("KyynPluginOptionsCodec",o) | Just o <- [options]] ++
      [("KyynPluginPositionCodec",p) | Just p <- [position]])
  entryPath <- relativePath "KyynPluginEntry.hs"
  let mode = case result of Nothing -> "Host.Acquisition"; Just _ -> "SDK.CapturedRead"
      resultType = case (result,position) of
        (Nothing,Nothing) -> "[SDK.EvidenceChange " ++ haskellType payload ++ "]"
        (Nothing,Just p) -> "(SDK.FetchResult " ++ haskellType payload ++ " " ++ haskellType p ++ ")"
        (Just r,_) -> haskellType r
      runtime = case result of
        Nothing | Just _ <- position ->
          "executeAcquisitionResult (withContextCodec " ++ argumentCodec ++ " Position.rootCodec) Payload.rootCodec " ++
          "(fetchResultCodec Payload.rootCodec Position.rootCodec) " ++
          (case options of Nothing -> "(\\(config,context) -> selected config context)"
                           Just _ -> "(\\((config,options),context) -> selected config options context)")
        Nothing -> case options of
          Nothing -> "executeAcquisition Arguments.rootCodec Payload.rootCodec selected"
          Just _ -> "executeAcquisition (withOptionsCodec Arguments.rootCodec Options.rootCodec) Payload.rootCodec (uncurry selected)"
        Just _ -> "executeCapturedRead Arguments.rootCodec Payload.rootCodec Result.rootCodec selected"
      argumentCodec = case options of
        Nothing -> "Arguments.rootCodec"
        Just _ -> "(withOptionsCodec Arguments.rootCodec Options.rootCodec)"
      entry = unlines $ ["module KyynPluginEntry where","import qualified " ++ implementationModule,
        "import qualified Kyyn.Plugin as SDK","import qualified Kyyn.Plugin.Host as Host",
        "import qualified KyynPluginArgumentsCodec as Arguments","import qualified KyynPluginPayloadCodec as Payload",
        "import Kyyn.Runtime.Plugin","import Kyyn.Runtime.PluginHost"] ++ imports (arguments:payload:maybe [] pure result ++ maybe [] pure options ++ maybe [] pure position) ++
        ["import qualified KyynPluginPositionCodec as Position" | Just _ <- [position]] ++
        ["import qualified KyynPluginOptionsCodec as Options" | Just _ <- [options]] ++
        ["import qualified KyynPluginResultCodec as Result" | Just _ <- [result]] ++
        ["selected :: " ++ haskellType arguments ++ maybe "" (\o -> " -> Maybe (" ++ haskellType o ++ ")") options ++
          maybe "" (\p -> " -> SDK.FetchContext " ++ haskellType p) position ++ " -> SDK.EvidenceSnapshot " ++ haskellType payload ++
          " -> " ++ mode ++ " " ++ haskellType payload ++ " (Either SDK.FetchError " ++ resultType ++ ")",
         "selected = " ++ implementation,"main :: IO ()","main = " ++ runtime]
  guestSources entryPath (authored ++ codecs ++ [(entryPath,utf8 entry)])

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
  (concatMap typeModules datatypes)]

utf8 :: String -> Bytes.ByteString
utf8 = Text.encodeUtf8 . Text.pack
