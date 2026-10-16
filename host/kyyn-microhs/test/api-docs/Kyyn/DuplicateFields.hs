{-# LANGUAGE DuplicateRecordFields, NoFieldSelectors #-}
module Kyyn.DuplicateFields (Public(..)) where

data Public = Public { shared :: String }
data Private = Private { shared :: Maybe String }
