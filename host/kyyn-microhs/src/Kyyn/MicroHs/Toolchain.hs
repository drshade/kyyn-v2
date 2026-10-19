module Kyyn.MicroHs.Toolchain (GuestToolchain(..), toolchainRevision) where

import Kyyn.Domain.Path (DirectoryScope)

newtype GuestToolchain = GuestToolchain DirectoryScope

toolchainRevision :: String
toolchainRevision = "e131f43eca647534193767d91ed3e93693afa2b9"
