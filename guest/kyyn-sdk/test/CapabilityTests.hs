-- Public capability helpers compose in different request-row orders, including
-- the terminal effect in an acquisition row. No provider or IO interpreter runs.
{-# LANGUAGE GADTs, TypeOperators, OverloadedStrings #-}
module Main (main) where

import qualified QueryCore
import Control.Monad (unless)
import Data.Functor.Identity (Identity(..))
import Kyyn.Plugin
import Kyyn.Plugin.Host
import Kyyn.Types.Program ((:+:)(..), interpretProgram)
import Kyyn.Types.PluginHost (Http(..), Waiting(..), Secrets(..))
import Kyyn.Types.Plugin (EvidenceRead(..), EvidenceSnapshot(..))

requestValue :: HttpRequest
requestValue = HttpRequest "GET" "https://example.invalid/" [] ""

response :: HttpResponse
response = HttpResponse 200 [] "captured"

reordered :: Program (Waiting :+: Secrets :+: Http) (Either HttpError HttpResponse)
reordered = getSecret "test-key" >> waitSeconds 0 >> sendHttp requestValue

handleReordered :: (Waiting :+: Secrets :+: Http) a -> Identity a
handleReordered (InLeft (WaitSeconds _)) = pure ()
handleReordered (InRight (InLeft (GetSecret key))) = pure (Left (SecretNotFound key))
handleReordered (InRight (InLeft (PutSecret _ _))) = pure ()
handleReordered (InRight (InRight (SendHttp _))) = pure (Right response)

terminal :: Program Http (Either HttpError HttpResponse)
terminal = sendHttp requestValue

handleTerminal :: Http a -> Identity a
handleTerminal (SendHttp _) = pure (Right response)

captured :: Program (Waiting :+: EvidenceRead Integer) (Either FetchError [EvidenceId])
captured = listEvidenceIds (EvidenceSnapshot "selected" :: EvidenceSnapshot Integer)

handleCaptured :: (Waiting :+: EvidenceRead Integer) a -> Identity a
handleCaptured (InLeft (WaitSeconds _)) = pure ()
handleCaptured (InRight (ListEvidenceIds _)) = pure (Right [EvidenceId "one"])
handleCaptured (InRight (ReadEvidence _ _)) = pure (Right Nothing)

-- Type-check the same public helper in the existing acquisition row too.
acquisition :: Acquisition Integer (Either FetchError [EvidenceId])
acquisition = listEvidenceIds (EvidenceSnapshot "selected" :: EvidenceSnapshot Integer)

main :: IO ()
main = do
  QueryCore.main
  unless (runIdentity (interpretProgram handleReordered reordered) == Right response)
    (fail "HTTP helper depended on the first row position")
  unless (runIdentity (interpretProgram handleTerminal terminal) == Right response)
    (fail "Single-capability row failed")
  unless (runIdentity (interpretProgram handleCaptured captured) == Right [EvidenceId "one"])
    (fail "Evidence helper depended on a special-case row instance")
  acquisition `seq` pure ()
  putStrLn "Capability helpers compose through shared membership constraints."
