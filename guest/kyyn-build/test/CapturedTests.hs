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

handle :: (Waiting :+: Calls) a -> Identity a
handle (InLeft (WaitSeconds _)) = pure ()
handle (InRight (ReadContent _ key)) = pure (Left (FetchError key))

main :: IO ()
main = do
  let result = runIdentity (interpretProgram handle (capturedContent (ConnectorInstance "files") "selected-key"))
  case result of
    Left (FetchError "selected-key") -> pure ()
    _ -> fail "Generated proxy changed its typed request"
  putStrLn "Compiler-resolved captured method bindings and signature rejection pass."
