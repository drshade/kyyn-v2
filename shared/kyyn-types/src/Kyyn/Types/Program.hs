{-# LANGUAGE GADTs, RankNTypes, TypeOperators #-}
module Kyyn.Types.Program (Program(..), (:+:)(..), request, interpretProgram) where

data (left :+: right) a = InLeft (left a) | InRight (right a)

-- | A result or a capability request with a continuation. Compose requests using do notation.
data Program request a where
  Pure :: a -> Program request a
  Request :: request x -> (x -> Program request a) -> Program request a

instance Functor (Program request) where
  fmap f (Pure a) = Pure (f a)
  fmap f (Request operation next) = Request operation (fmap f . next)

instance Applicative (Program request) where
  pure = Pure
  functions <*> arguments = functions >>= \f -> fmap f arguments

instance Monad (Program request) where
  Pure a >>= next = next a
  Request operation next >>= f = Request operation (\value -> next value >>= f)

-- | Lift a single typed capability request into a program.
request :: effect a -> Program effect a
request operation = Request operation Pure

-- | Handle each request with the supplied interpreter and resume its continuation.
interpretProgram :: Monad m => (forall x. effect x -> m x) -> Program effect a -> m a
interpretProgram _ (Pure a) = pure a
interpretProgram handler (Request operation next) = handler operation >>= interpretProgram handler . next
