module Kyyn.DocFixture (documented, ordinary, detached, Item, Alias) where

-- An unrelated comment above the documentation block.
-- | Return the supplied text: café.
--
--   An indented example.
documented :: String -> String
documented value = value

-- This ordinary comment must not become documentation.
ordinary :: Bool
ordinary = True

-- | This comment is detached from its declaration.

detached :: Bool
detached = True

-- | An abstract item. Its constructor stays private.
data Item = PrivateItem

-- | A documented alias.
type Alias = String
