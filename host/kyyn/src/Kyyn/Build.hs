{-# LANGUAGE CPP #-}
module Kyyn.Build (buildRevision) where

buildRevision :: Maybe String
#ifdef KYYN_BUILD_REVISION
buildRevision = Just KYYN_BUILD_REVISION
#else
buildRevision = Nothing
#endif
