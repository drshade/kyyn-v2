{-# LANGUAGE TypeOperators, DuplicateRecordFields #-}
module Kyyn.Plugin.Host
  ( NetworkHost, NetworkAcquisition, PluginLogin, HttpRequest(..), HttpResponse(..), HttpError(..), SecretError(..), LoginError(..)
  , sendHttp, getSecret, putSecret, waitSeconds, displayInstructions ) where

import Kyyn.Types.Program
import Kyyn.Types.Plugin (EvidenceRead)
import Kyyn.Types.PluginHost

type NetworkHost rest = Program (Http :+: (Secrets :+: (Waiting :+: rest)))
type NetworkAcquisition payload = NetworkHost (EvidenceRead payload)
type PluginLogin = NetworkHost LoginInteraction

-- | Send a text request; the caller handles HTTP status codes and retry policy.
sendHttp :: HttpRequest -> Program (Http :+: rest) (Either HttpError HttpResponse)
sendHttp = request . InLeft . SendHttp

-- | Read a named secret from this KB's local store.
getSecret :: String -> Program (Http :+: (Secrets :+: rest)) (Either SecretError String)
getSecret = request . InRight . InLeft . GetSecret

-- | Replace a named secret, including a rotated refresh token.
putSecret :: String -> String -> Program (Http :+: (Secrets :+: rest)) ()
putSecret key = request . InRight . InLeft . PutSecret key

-- | Wait a nonnegative number of seconds. Cancellation interrupts the wait.
waitSeconds :: Int -> Program (Http :+: (Secrets :+: (Waiting :+: rest))) ()
waitSeconds = request . InRight . InRight . InLeft . WaitSeconds

-- | Show instructions during an explicitly invoked login.
displayInstructions :: String -> PluginLogin ()
displayInstructions = request . InRight . InRight . InRight . DisplayInstructions
