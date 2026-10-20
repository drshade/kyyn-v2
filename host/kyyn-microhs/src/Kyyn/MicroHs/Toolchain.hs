module Kyyn.MicroHs.Toolchain (GuestToolchain(..), toolchainRevision) where

import Kyyn.Domain.Path (DirectoryScope)

newtype GuestToolchain = GuestToolchain DirectoryScope

toolchainRevision :: String
toolchainRevision = "6174d880c1b41450ec59713cb54e40b2b59d0323"
