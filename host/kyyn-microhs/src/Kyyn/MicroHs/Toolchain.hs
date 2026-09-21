module Kyyn.MicroHs.Toolchain (GuestToolchain(..), toolchainRevision) where

import Kyyn.Domain.Path (DirectoryScope)

newtype GuestToolchain = GuestToolchain DirectoryScope

toolchainRevision :: String
toolchainRevision = "3322c60aad59da83fee9f870c37dab56e56238b5"
