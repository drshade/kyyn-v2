{-# LANGUAGE RankNTypes #-}
module Kyyn.Optics (Lens, Lens', lens, view, set, over) where

import Data.Functor.Const (Const(..))
import Data.Functor.Identity (Identity(..))

-- | Focus on part of a structure, allowing both the part and the structure to change type.
type Lens s t a b = forall f. Functor f => (a -> f b) -> s -> f t
-- | An optic that preserves the types of the structure and its focused part.
type Lens' s a = Lens s s a a

lens :: (s -> a) -> (s -> b -> t) -> Lens s t a b
lens getter setter focus source = setter source <$> focus (getter source)

view :: Lens' s a -> s -> a
view optic = getConst . optic Const

over :: Lens s t a b -> (a -> b) -> s -> t
over optic transform = runIdentity . optic (Identity . transform)

set :: Lens s t a b -> b -> s -> t
set optic value = over optic (const value)
