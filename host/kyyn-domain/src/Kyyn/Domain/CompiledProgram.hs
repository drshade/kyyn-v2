module Kyyn.Domain.CompiledProgram (BuildIdentity(..), CompiledProgram(..)) where

import Data.ByteString (ByteString)
import Kyyn.Domain.Path (RelativePath)

data BuildIdentity = BuildIdentity
  { toolchainRevision :: String
  , sourcesDigest :: ByteString
  } deriving (Eq, Show)

data CompiledProgram = CompiledProgram
  { identity :: BuildIdentity
  , artifact :: (RelativePath, ByteString)
  } deriving (Eq, Show)
