{-# LANGUAGE CPP #-}
module Kyyn.CppFixture (selected) where

#ifdef __MHS__
-- | The MicroHs branch, including its source documentation.
selected :: String
selected = "microhs"
#else
selected :: Bool
selected = False
#endif
