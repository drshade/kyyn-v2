module Kyyn.ImplicitExports where

data Public = Public deriving (Eq, Show)

infixr 0 $
($) :: (a -> b) -> a -> b
f $ x = f x

named' :: Public
named' = Public
