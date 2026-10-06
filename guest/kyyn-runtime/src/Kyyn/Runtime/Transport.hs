{-# LANGUAGE CPP #-}
module Kyyn.Runtime.Transport
  ( Transport, withTransport, readFrame, writeFrame, readJson, writeJson, writeValueFrame ) where

import Control.Exception (evaluate)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.IO
import Kyyn.Runtime.Json (printChunks)
import Text.JSON.Types (JSValue)

data Transport = Transport Handle Handle

withTransport :: (Transport -> IO a) -> IO a
#ifdef __MHS__
withTransport action = withBinaryFile "/dev/stdin" ReadMode $ \input ->
  withBinaryFile "/dev/stdout" WriteMode $ \output -> action (Transport input output)
#else
withTransport action = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  action (Transport stdin stdout)
#endif

readFrame :: Transport -> IO (B.ByteString, B.ByteString)
readFrame (Transport input _) = (,) <$> section <*> section
  where
    section = chunks []
    chunks acc = do
      count <- header []
      if count == 0 then evaluate (B.concat (reverse acc)) else do
        bytes <- exact count []
        chunks (bytes:acc)
    header acc = do
      byte <- exact 1 []
      if B.head byte == 10 then case reads (reverse acc) of
        [(n,"")] | n >= 0 && n <= 65536 && show n == reverse acc -> pure n
        _ -> fail "Invalid host chunk length"
      else if length acc >= 5 || B.head byte < 48 || B.head byte > 57
        then fail "Invalid host chunk length"
        else header (C.head byte:acc)
    exact 0 acc = evaluate (B.concat (reverse acc))
    exact n acc = do
      bytes <- B.hGet input n
      if B.null bytes then fail "Host closed an incomplete frame"
        else exact (n-B.length bytes) (bytes:acc)

writeFrame :: Transport -> [B.ByteString] -> B.ByteString -> IO ()
writeFrame (Transport _ output) metadata body = do
  mapM_ chunks metadata
  B.hPut output (C.pack "0\n")
  chunks body
  B.hPut output (C.pack "0\n")
  hFlush output
  where
    chunks bytes | B.null bytes = pure ()
                 | otherwise = do
        let (part,rest) = B.splitAt 65536 bytes
        B.hPut output (C.pack (show (B.length part) ++ "\n"))
        B.hPut output part
        chunks rest

readJson :: Transport -> IO String
readJson transport = do
  (metadata,body) <- readFrame transport
  if B.null body then pure (T.unpack (TE.decodeUtf8 metadata))
    else fail "Unexpected raw body"

writeJson :: Transport -> String -> IO ()
writeJson transport text = writeFrame transport (chunks text) B.empty
  where
    chunks [] = []
    chunks input = let (part,rest) = splitAt 8192 input
                  in TE.encodeUtf8 (T.pack part) : chunks rest

writeValueFrame :: Transport -> JSValue -> B.ByteString -> IO ()
writeValueFrame (Transport input output) value body = do
  emit [] 0 (printChunks value)
  -- writeFrame finishes the metadata section, then writes the body section.
  writeFrame (Transport input output) [] body
  where
    emit pending _ [] = flush pending
    emit _ _ (Left message:_) = fail message
    emit pending size (Right characters:rest) = do
      let (part,remaining) = splitAt (8192-size) characters
          size' = size + length part
          pending' = part : pending
      if size' == 8192 then do
        flush pending'
        emit [] 0 (Right remaining:rest)
      else emit pending' size' rest
    flush pending = do
      let bytes = TE.encodeUtf8 (T.pack (concat (reverse pending)))
      if B.null bytes then pure () else do
        B.hPut output (C.pack (show (B.length bytes) ++ "\n"))
        B.hPut output bytes
