{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators, DuplicateRecordFields, FlexibleContexts #-}
module Kyyn.Plugin.Host
  ( NetworkHost, Acquisition, PluginLogin, HttpRequest(..), HttpResponse(..), HttpError(..), SecretError(..), LoginError(..)
  , sendHttp, getSecret, putSecret, waitSeconds, displayInstructions, listFiles, readTextFile
  , BlobRef(..), BlobDownload(..), BlobResponse(..), storeBlob, digestText ) where

import Data.Text (Text)

import Kyyn.Types.Program
import qualified Kyyn.Types.Program as Program
import Kyyn.Types.Plugin (FileRead(..), EvidenceRead, FetchError, CapturedText)
import Kyyn.Types.PluginHost
import Kyyn.Types.Blob

-- | HTTP, secret storage and waiting, combined with an additional capability row.
type NetworkHost rest = Program (Http :+: (Secrets :+: (Waiting :+: rest)))
-- | Fetch source data using HTTP, files, secrets, waiting and prior captured evidence.
type Acquisition payload = NetworkHost (FileRead :+: (BlobAcquisition :+: (ContentDigest :+: EvidenceRead payload)))

-- | Lowercase SHA-256 of each input's exact UTF-8 bytes, preserving list order.
digestText :: Member ContentDigest row => [Text] -> Program row [Text]
digestText = Program.request . inject . DigestText

-- | Download directly into the selected instance's host-side blob store.
storeBlob :: Member BlobAcquisition row => BlobDownload -> Program row (Either FetchError BlobResponse)
storeBlob = Program.request . inject . StoreBlob
-- | An explicit login program that can display instructions to the user.
type PluginLogin = NetworkHost LoginInteraction

-- | Enumerate paths relative to a directory, itself KB-relative or absolute.
listFiles :: Member FileRead row => Text -> Bool -> Program row (Either FetchError [Text])
listFiles directory recursive = Program.request (inject (ListFiles directory recursive))

-- | Capture source text and its fingerprint together.
readTextFile :: Member FileRead row => Text -> Program row (Either FetchError CapturedText)
readTextFile path = Program.request (inject (ReadTextFile path))

-- | Send a text request; the caller handles HTTP status codes and retry policy.
sendHttp :: Member Http row => HttpRequest -> Program row (Either HttpError HttpResponse)
sendHttp = Program.request . inject . SendHttp

-- | Read a named secret from this KB's local store.
getSecret :: Member Secrets row => Text -> Program row (Either SecretError Text)
getSecret = Program.request . inject . GetSecret

-- | Replace a named secret, including a rotated refresh token.
putSecret :: Member Secrets row => Text -> Text -> Program row ()
putSecret key = Program.request . inject . PutSecret key

-- | Wait a nonnegative number of seconds. Cancellation interrupts the wait.
waitSeconds :: Member Waiting row => Int -> Program row ()
waitSeconds = Program.request . inject . WaitSeconds

-- | Show instructions during an explicitly invoked login.
displayInstructions :: Member LoginInteraction row => Text -> Program row ()
displayInstructions = Program.request . inject . DisplayInstructions
