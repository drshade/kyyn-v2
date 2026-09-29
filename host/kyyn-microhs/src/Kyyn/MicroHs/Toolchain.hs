module Kyyn.MicroHs.Toolchain (GuestToolchain(..), toolchainRevision) where

import Kyyn.Domain.Path (DirectoryScope)

newtype GuestToolchain = GuestToolchain DirectoryScope

toolchainRevision :: String
toolchainRevision = "8bf3d4d4242c8707b31c2338716977d24a95ad39"
