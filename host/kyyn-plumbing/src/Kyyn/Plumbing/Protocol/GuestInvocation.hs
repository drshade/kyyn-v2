{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Plumbing.Protocol.GuestInvocation (encodeInvocation) where

import Data.Aeson (Value, encode)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import Kyyn.Domain.CompiledEntry (CompiledEntry, entryDescription)
import Kyyn.Types.Guest (GuestRequest(..), entryName)

encodeInvocation :: CompiledEntry -> Value -> ByteString
encodeInvocation entry argument = Lazy.toStrict (encode (Invoke (entryName (entryDescription entry)) argument))
