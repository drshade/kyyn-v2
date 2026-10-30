{-# LANGUAGE GADTs, RankNTypes, TypeOperators #-}
module Kyyn.Types.Program (Program(..), (:+:)(..), request, concurrently, concurrentlyE, interpretProgram) where

data (left :+: right) a = InLeft (left a) | InRight (right a)

-- | A result or a capability request with a continuation. Compose requests using do notation.
data Program request a where
  Pure :: a -> Program request a
  Request :: request x -> (x -> Program request a) -> Program request a
  Concurrent :: [Program request x] -> ([x] -> Program request a) -> Program request a
  ConcurrentEither :: [Program request (Either e x)] -> (Either e [x] -> Program request a) -> Program request a

instance Functor (Program request) where
  fmap f (Pure a) = Pure (f a)
  fmap f (Request operation next) = Request operation (fmap f . next)
  fmap f (Concurrent branches next) = Concurrent branches (fmap f . next)
  fmap f (ConcurrentEither branches next) = ConcurrentEither branches (fmap f . next)

instance Applicative (Program request) where
  pure = Pure
  functions <*> arguments = functions >>= \f -> fmap f arguments

instance Monad (Program request) where
  Pure a >>= next = next a
  Request operation next >>= f = Request operation (\value -> next value >>= f)
  Concurrent branches next >>= f = Concurrent branches (\values -> next values >>= f)
  ConcurrentEither branches next >>= f = ConcurrentEither branches (\values -> next values >>= f)

-- | Lift a single typed capability request into a program.
request :: effect a -> Program effect a
request operation = Request operation Pure

-- | Handle each request with the supplied interpreter and resume its continuation.
interpretProgram :: Monad m => (forall x. effect x -> m x) -> Program effect a -> m a
interpretProgram _ (Pure a) = pure a
interpretProgram handler (Request operation next) = handler operation >>= interpretProgram handler . next
interpretProgram handler (Concurrent branches next) = mapM (interpretProgram handler) branches >>= interpretProgram handler . next
interpretProgram handler (ConcurrentEither branches next) = sequenceBranches branches >>= interpretProgram handler . next
  where
    sequenceBranches [] = pure (Right [])
    sequenceBranches (branch:rest) = do
      result <- interpretProgram handler branch
      case result of
        Left problem -> pure (Left problem)
        Right value -> fmap (fmap (value:)) (sequenceBranches rest)

-- | Independent workflows, with results in input order. Scheduling belongs to the interpreter.
concurrently :: [Program request a] -> Program request [a]
concurrently branches = Concurrent branches Pure

-- | Independent fallible workflows. Acquisition stops a failed group at a round boundary.
concurrentlyE :: [Program request (Either e a)] -> Program request (Either e [a])
concurrentlyE branches = ConcurrentEither branches Pure
