{-# LANGUAGE RankNTypes #-}
module Kyyn.Optics (Lens, Lens', lens, view, set, over) where

import Data.Functor.Const (Const(..))
import Data.Functor.Identity (Identity(..))

-- | Focus on part of a structure, allowing both the part and the structure to change type.
type Lens s t a b = forall f. Functor f => (a -> f b) -> s -> f t
-- | An optic that preserves the types of the structure and its focused part.
type Lens' s a = Lens s s a a

-- | Construct an optic from a getter and a setter. The setter receives the original structure first.
lens :: (s -> a) -> (s -> b -> t) -> Lens s t a b
lens getter setter focus source = setter source <$> focus (getter source)

-- | Read the part of a structure selected by an optic.
view :: Lens' s a -> s -> a
view optic = getConst . optic Const

-- | Transform the selected part, returning the updated structure.
over :: Lens s t a b -> (a -> b) -> s -> t
over optic transform = runIdentity . optic (Identity . transform)

-- | Replace the selected part, returning the updated structure.
set :: Lens s t a b -> b -> s -> t
set optic value = over optic (const value)
