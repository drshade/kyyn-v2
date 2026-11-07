{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Plumbing.Protocol.GuestInvocation (encodeInvocation) where

import Data.Aeson (Value, encode)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import Kyyn.Domain.CompiledEntry (CompiledEntry, invocationName)
import Kyyn.Types.Guest (GuestRequest(..))

encodeInvocation :: CompiledEntry -> Value -> ByteString
encodeInvocation entry argument = Lazy.toStrict (encode (Invoke (invocationName entry) argument))
