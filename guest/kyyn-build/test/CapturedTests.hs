-- Compiler-resolved method GADTs retain private plugin result types and expanded
-- library aliases. The generated proxy composes through Member in a reordered
-- row; no provider or host IO is performed. A malformed registration is refused
-- by the splice before an adapter is generated.
{-# LANGUAGE TemplateHaskell, GADTs, TypeOperators, FlexibleContexts, OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}
module Main (main) where

import Control.Monad (unless)
import Data.Functor.Identity (Identity(..))
import Language.Haskell.TH (mkName, recover)
import Kyyn.Build.Captured
import Kyyn.Types.Plugin (ConnectorInstance(..), FetchError(..))
import Kyyn.Types.Evidence (EvidenceId(..))
import Kyyn.Types.PluginHost (Waiting(..))
import Kyyn.Types.Program ((:+:)(..), interpretProgram)
import qualified CapturedProvider

$(capturedCalls (mkName "Calls")
  [CapturedBinding (mkName "ReadContent") (mkName "capturedContent") (mkName "Files")
    'CapturedProvider.content "test/CapturedProvider.hs"])

$(do
  refused <- recover (pure True) (capturedCalls (mkName "BadCalls")
    [CapturedBinding (mkName "Bad") (mkName "badProxy") (mkName "BadFiles")
      'CapturedProvider.bad "test/CapturedProvider.hs"] >> pure False)
  unless refused (fail "Malformed captured method signature was accepted")
  pure [])

$(toolCalls (mkName "FullCalls")
  [ConnectorBinding (mkName "AllFiles") 'CapturedProvider.fetch "test/CapturedProvider.hs"]
  [CapturedBinding (mkName "ReadFullContent") (mkName "fullContent") (mkName "AllFiles")
    'CapturedProvider.content "test/CapturedProvider.hs"])

handleFull :: (Waiting :+: FullCalls) a -> Identity a
handleFull (InLeft (WaitSeconds _)) = pure ()
handleFull (InRight (JudgementCall _)) = pure (Left "unavailable")
handleFull (InRight (ModelCall _)) = pure (Left "unavailable")
handleFull (InRight (ObserveFlow _)) = pure ()
handleFull (InRight (ListEvidence_AllFiles _)) = pure (Right [])
handleFull (InRight (ReadEvidence_AllFiles _ _)) = pure (Right Nothing)
handleFull (InRight (ReadFullContent _ key)) = pure (Left (FetchError key))

handle :: (Waiting :+: Calls) a -> Identity a
handle (InLeft (WaitSeconds _)) = pure ()
handle (InRight (ReadContent _ key)) = pure (Left (FetchError key))

main :: IO ()
main = do
  let result = runIdentity (interpretProgram handle (capturedContent (ConnectorInstance "files") "selected-key"))
  case result of
    Left (FetchError "selected-key") -> pure ()
    _ -> fail "Generated proxy changed its typed request"
  unless (runIdentity (interpretProgram handleFull (listEvidence_AllFiles (ConnectorInstance "files"))) == Right [])
    (fail "Generated evidence enumeration proxy changed its request")
  case runIdentity (interpretProgram handleFull (readEvidence_AllFiles (ConnectorInstance "files") (EvidenceId "item"))) of
    Right Nothing -> pure ()
    _ -> fail "Generated evidence proxy changed its typed request"
  case runIdentity (interpretProgram handleFull (fullContent (ConnectorInstance "files") "full-key")) of
    Left (FetchError "full-key") -> pure ()
    _ -> fail "Full Calls algebra changed the captured proxy"
  putStrLn "Compiler-resolved captured method bindings and signature rejection pass."
