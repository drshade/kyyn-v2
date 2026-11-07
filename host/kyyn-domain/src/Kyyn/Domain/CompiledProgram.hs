module Kyyn.Domain.CompiledProgram (BuildIdentity(..), CompiledProgram(..)) where

import Data.ByteString (ByteString)

-- Nix owns the compiler/library/build-option identity; source capture also
-- includes the fixed entry selection. No mutable checkout is resolved at invoke.
data BuildIdentity = BuildIdentity
  { sourcesDigest :: ByteString
  , targetSystem :: String
  , derivationPath :: FilePath
  , outputPath :: FilePath
  } deriving (Eq, Show)

data CompiledProgram = CompiledProgram
  { identity :: BuildIdentity
  , executable :: FilePath
  , retentionRoot :: FilePath
  } deriving (Eq, Show)
