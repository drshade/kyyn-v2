{-# LANGUAGE GADTs #-}
module Kyyn.DataFixture
  ( Choice(..), Record(..), Wrapped(..), Abstract, AbstractNew
  , Partial(Visible), HiddenFields(HiddenFields), Expr(..)
  ) where

data Choice a = Empty | Full a
data Record = Record { title :: String, count :: Int, note :: Maybe String, total :: !(Maybe Int) }
newtype Wrapped a = Wrapped [a]
data Abstract = Private
newtype AbstractNew = PrivateNew String
data Partial = Visible Int | Secret Bool
data HiddenFields = HiddenFields { hidden :: String }
data Expr a where
  Number :: Int -> Expr Int
  Apply :: (a -> b) -> Expr a -> Expr b
