{-# LANGUAGE GHC2021, OverloadedStrings #-}
{-# OPTIONS_GHC -Werror #-}
module Kyyn.MicroHs.Interpreter.InspectionCache (InspectionCache(..), cachedInspection, inspectionKey) where

import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.List (sortOn)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Numeric (showHex)
import Effectful (Eff, IOE, (:>), liftIO)
import GHC.Clock (getMonotonicTimeNSec)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Path
import Kyyn.MicroHs.Timing (timingEnabled, emitTiming)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem, readOptionalBytes, replaceBytes)

data InspectionCache = InspectionCache String DirectoryScope

inspectionKey :: String -> String -> [(RelativePath,Bytes.ByteString)] -> RelativePath
inspectionKey revision settings sources = either error id . relativePath $
  concatMap hex (Bytes.unpack (SHA256.hash (Lazy.toStrict (Builder.toLazyByteString contents)))) ++ ".dhall"
  where
    contents = string revision <> string settings <>
      foldMap (\(path,bytes) -> string (relativeName path) <> framed bytes) (sortOn fst sources)
    string = framed . Text.encodeUtf8 . Text.pack
    framed bytes = Builder.word64BE (fromIntegral (Bytes.length bytes)) <> Builder.byteString bytes
    hex byte = let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits

cachedInspection
  :: (FileSystem :> es, IOE :> es)
  => Maybe InspectionCache -> String -> String -> String -> [(RelativePath,Bytes.ByteString)]
  -> (a -> Eff es (Either [Diagnostic] Bytes.ByteString))
  -> (Bytes.ByteString -> Eff es (Either [Diagnostic] a))
  -> Eff es (Either [Diagnostic] a) -> Eff es (Either [Diagnostic] a)
cachedInspection Nothing _ _ _ _ _ _ action = action
cachedInspection (Just (InspectionCache revision directory)) kind label settings sources encode decode action = do
  let key = inspectionKey revision (show (kind,settings)) sources
  timed <- liftIO timingEnabled
  start <- if timed then liftIO getMonotonicTimeNSec else pure 0
  existing <- readOptionalBytes directory key
  case existing of
    Just bytes | not (Bytes.null bytes) -> do
      result <- decode bytes
      case result of
        Left _ -> pure (Left [errorDiagnostic "inspection.cache-invalid"
          ("Cannot read inspection cache; delete " ++ scopePath directory ++ " and retry.")])
        Right value -> do
          if timed then liftIO (emitTiming (kind ++ "-hit") label start) else pure ()
          pure (Right value)
    _ -> do
      result <- action
      case result of
        Left diagnostics -> pure (Left diagnostics)
        Right value -> do
          encoded <- encode value
          case encoded of
            Left diagnostics -> pure (Left diagnostics)
            Right bytes -> do
              let ignore = either error id (relativePath ".gitignore")
              ignored <- readOptionalBytes directory ignore
              case ignored of
                Nothing -> replaceBytes directory ignore "*\n"
                Just _ -> pure ()
              replaceBytes directory key bytes
              pure (Right value)
