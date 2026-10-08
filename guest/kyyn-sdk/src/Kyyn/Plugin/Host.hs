{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators, DuplicateRecordFields #-}
module Kyyn.Plugin.Host
  ( NetworkHost, Acquisition, PluginLogin, HttpRequest(..), HttpResponse(..), HttpError(..), SecretError(..), LoginError(..)
  , sendHttp, getSecret, putSecret, waitSeconds, displayInstructions, listFiles, readTextFile
  , BlobRef(..), BlobDownload(..), BlobResponse(..), storeBlob ) where

import Data.Text (Text)

import Kyyn.Types.Program
import qualified Kyyn.Types.Program as Program
import Kyyn.Types.Plugin (FileRead(..), EvidenceRead, FetchError, CapturedText)
import Kyyn.Types.PluginHost
import Kyyn.Types.Blob

-- | HTTP, secret storage and waiting, combined with an additional capability row.
type NetworkHost rest = Program (Http :+: (Secrets :+: (Waiting :+: rest)))
-- | Fetch source data using HTTP, files, secrets, waiting and prior captured evidence.
type Acquisition payload = NetworkHost (FileRead :+: (BlobAcquisition :+: EvidenceRead payload))

-- | Download directly into the selected instance's host-side blob store.
storeBlob :: BlobDownload -> Acquisition payload (Either FetchError BlobResponse)
storeBlob = Program.request . InRight . InRight . InRight . InRight . InLeft . StoreBlob
-- | An explicit login program that can display instructions to the user.
type PluginLogin = NetworkHost LoginInteraction

-- | Enumerate source files relative to the selected absolute directory.
listFiles :: FilePath -> Bool -> Acquisition payload (Either FetchError [FilePath])
listFiles directory recursive = Program.request (InRight (InRight (InRight (InLeft (ListFiles directory recursive)))))

-- | Capture source text and its fingerprint together.
readTextFile :: FilePath -> Acquisition payload (Either FetchError CapturedText)
readTextFile path = Program.request (InRight (InRight (InRight (InLeft (ReadTextFile path)))))

-- | Send a text request; the caller handles HTTP status codes and retry policy.
sendHttp :: HttpRequest -> Program (Http :+: rest) (Either HttpError HttpResponse)
sendHttp = Program.request . InLeft . SendHttp

-- | Read a named secret from this KB's local store.
getSecret :: Text -> Program (Http :+: (Secrets :+: rest)) (Either SecretError Text)
getSecret = Program.request . InRight . InLeft . GetSecret

-- | Replace a named secret, including a rotated refresh token.
putSecret :: Text -> Text -> Program (Http :+: (Secrets :+: rest)) ()
putSecret key = Program.request . InRight . InLeft . PutSecret key

-- | Wait a nonnegative number of seconds. Cancellation interrupts the wait.
waitSeconds :: Int -> Program (Http :+: (Secrets :+: (Waiting :+: rest))) ()
waitSeconds = Program.request . InRight . InRight . InLeft . WaitSeconds

-- | Show instructions during an explicitly invoked login.
displayInstructions :: Text -> PluginLogin ()
displayInstructions = Program.request . InRight . InRight . InRight . DisplayInstructions
