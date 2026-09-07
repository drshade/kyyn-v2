module Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure) where

import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import Kyyn.Domain.Failure (OperationalFailure)

type Failure = Error OperationalFailure

raiseFailure :: Failure :> es => OperationalFailure -> Eff es a
raiseFailure = throwError
