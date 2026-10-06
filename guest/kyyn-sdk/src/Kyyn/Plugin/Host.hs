{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators, DuplicateRecordFields #-}
module Kyyn.Plugin.Host
  ( NetworkHost, Acquisition, PluginLogin, HttpRequest(..), HttpResponse(..), HttpError(..), SecretError(..), LoginError(..)
  , sendHttp, getSecret, putSecret, waitSeconds, displayInstructions, listFiles, readTextFile ) where

import Data.Text (Text)

import Kyyn.Types.Program
import Kyyn.Types.Plugin (FileRead(..), EvidenceRead, FetchError, CapturedText)
import Kyyn.Types.PluginHost

-- | HTTP, secret storage and waiting, combined with an additional capability row.
type NetworkHost rest = Program (Http :+: (Secrets :+: (Waiting :+: rest)))
-- | Fetch source data using HTTP, files, secrets, waiting and prior captured evidence.
type Acquisition payload = NetworkHost (FileRead :+: EvidenceRead payload)
-- | An explicit login program that can display instructions to the user.
type PluginLogin = NetworkHost LoginInteraction

-- | Enumerate source files relative to the selected absolute directory.
listFiles :: FilePath -> Bool -> Acquisition payload (Either FetchError [FilePath])
listFiles directory recursive = request (InRight (InRight (InRight (InLeft (ListFiles directory recursive)))))

-- | Capture source text and its fingerprint together.
readTextFile :: FilePath -> Acquisition payload (Either FetchError CapturedText)
readTextFile path = request (InRight (InRight (InRight (InLeft (ReadTextFile path)))))

-- | Send a text request; the caller handles HTTP status codes and retry policy.
sendHttp :: HttpRequest -> Program (Http :+: rest) (Either HttpError HttpResponse)
sendHttp = request . InLeft . SendHttp

-- | Read a named secret from this KB's local store.
getSecret :: Text -> Program (Http :+: (Secrets :+: rest)) (Either SecretError Text)
getSecret = request . InRight . InLeft . GetSecret

-- | Replace a named secret, including a rotated refresh token.
putSecret :: Text -> Text -> Program (Http :+: (Secrets :+: rest)) ()
putSecret key = request . InRight . InLeft . PutSecret key

-- | Wait a nonnegative number of seconds. Cancellation interrupts the wait.
waitSeconds :: Int -> Program (Http :+: (Secrets :+: (Waiting :+: rest))) ()
waitSeconds = request . InRight . InRight . InLeft . WaitSeconds

-- | Show instructions during an explicitly invoked login.
displayInstructions :: Text -> PluginLogin ()
displayInstructions = request . InRight . InRight . InRight . DisplayInstructions
