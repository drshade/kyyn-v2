{-# LANGUAGE GADTs #-}
module Kyyn.Plumbing.Interpreter.ContentDigest (runContentDigest) where
import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Plumbing.Capability.ContentDigest
import Numeric (showHex)

runContentDigest :: Eff (ContentDigest : es) a -> Eff es a
runContentDigest = interpret $ \_ (DigestText values) -> pure (map digest values)
  where
    digest = Text.pack . concatMap byte . Bytes.unpack . SHA.hash . Text.encodeUtf8
    byte value = let hex = showHex value "" in replicate (2 - length hex) '0' ++ hex
