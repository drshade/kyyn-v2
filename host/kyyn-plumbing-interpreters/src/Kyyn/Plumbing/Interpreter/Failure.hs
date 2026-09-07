{-# LANGUAGE DataKinds #-}
module Kyyn.Plumbing.Interpreter.Failure (runFailure) where

import Effectful (Eff)
import Effectful.Error.Static (runErrorNoCallStack)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Plumbing.Capability.Failure (Failure)

runFailure :: Eff (Failure : es) a -> Eff es (Either OperationalFailure a)
runFailure = runErrorNoCallStack
