module Kyyn.MicroHs.Toolchain (GuestToolchain(..), toolchainRevision) where

import Kyyn.Domain.Path (DirectoryScope)

newtype GuestToolchain = GuestToolchain DirectoryScope

toolchainRevision :: String
toolchainRevision = "455782164e75998b140d869c1b7cdde0c8a21508"
