module Kyyn.Plumbing.Protocol.Frame
  ( Frame(..), jsonFrame, encodeFrame, readFrame, chunkSize ) where

import Control.Monad (when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Control.Monad.Trans.State.Strict (StateT, runStateT, get, put)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C

data Frame = Frame { metadata :: B.ByteString, body :: B.ByteString }
  deriving (Eq, Show)

jsonFrame :: B.ByteString -> Frame
jsonFrame bytes = Frame bytes B.empty

chunkSize :: Int
chunkSize = 65536

encodeFrame :: Frame -> [B.ByteString]
encodeFrame (Frame metadata body) = section metadata ++ section body
  where
    section bytes
      | B.null bytes = ["0\n"]
      | otherwise = let (chunk,rest) = B.splitAt chunkSize bytes
                    in C.pack (show (B.length chunk) ++ "\n") : chunk : section rest

readFrame :: Monad m => m (Maybe B.ByteString) -> B.ByteString -> m (Either String (Frame, B.ByteString))
readFrame next buffered
  | B.null buffered = do
      first <- next
      case first of
        Nothing -> pure (Left "Guest exited without a response")
        Just bytes | B.null bytes -> pure (Left "Empty transport read")
                   | otherwise -> parse bytes
  | otherwise = parse buffered
  where
    parse = runExceptT . runStateT (Frame <$> section <*> section)
    section = chunks []
    chunks acc = do
      count <- header []
      if count == 0 then pure (B.concat (reverse acc)) else do
        bytes <- exact count []
        chunks (bytes:acc)
    header acc = do
      byte <- exact 1 []
      if byte == "\n" then case reads (reverse acc) of
        [(n,"")] | n >= 0 && n <= chunkSize && show n == reverse acc -> pure n
        _ -> throwProtocol "Invalid guest chunk length"
      else do
        when (length acc >= 5 || B.head byte < 48 || B.head byte > 57)
          (throwProtocol "Invalid guest chunk length")
        header (C.head byte:acc)
    exact 0 acc = pure (B.concat (reverse acc))
    exact n acc = do
      available <- get
      if B.null available then do
        incoming <- lift (lift next)
        case incoming of
          Nothing -> throwProtocol "Guest exited within a frame"
          Just bytes | B.null bytes -> throwProtocol "Empty transport read"
                     | otherwise -> put bytes >> exact n acc
      else do
        let (part,rest) = B.splitAt n available
        put rest
        exact (n-B.length part) (part:acc)

throwProtocol :: Monad m => String -> StateT B.ByteString (ExceptT String m) a
throwProtocol = lift . throwE
