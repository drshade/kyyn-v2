{-# LANGUAGE OverloadedStrings, OverloadedRecordDot, TypeApplications #-}
module Kyyn.Composition.FlowValues (FlowValues(..), readFlowValues, readFlowValuesMany) where

import Control.Monad (forM)
import Data.List (nub)
import Effectful (Eff, (:>))
import Effectful.Error.Static (catchError)
import Kyyn.Domain.Contract (contractShape)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure, operationalDiagnostic)
import Kyyn.Domain.FlowBundleId (FlowBundleId)
import Kyyn.Domain.FlowClosure (FlowDeclaration(..))
import Kyyn.Domain.FlowInstance
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Porcelain.Capability.FlowPreparation (FlowBundle(..), PreparedFlowEntry(..))
import Kyyn.Porcelain.Capability.FlowStore (FlowStore, readBundleDescription)

import Kyyn.Surfaces.Flows (FlowValues(..))

-- Metadata only: values are rendered through captured contracts even when the
-- executable has gone away. Current KB source and secrets are never consulted.
readFlowValues :: (FlowStore :> es, DhallHandling :> es, Failure :> es)
  => FlowInstance -> Eff es FlowValues
readFlowValues item = case item.launch.owner of
  External -> pure (FlowValues Nothing Nothing [])
  Hosted identity _ -> readCaptured identity >>= renderCaptured item

-- One command owns this association list. A bundle's read failure is cached
-- alongside successful metadata, so every instance gets the same diagnostic.
readFlowValuesMany :: (FlowStore :> es, DhallHandling :> es, Failure :> es)
  => [FlowInstance] -> Eff es [FlowValues]
readFlowValuesMany items = do
  bundles <- forM (nub [identity | item <- items, Hosted identity _ <- [item.launch.owner]]) $ \identity -> do
    captured <- readCaptured identity
    pure (identity,captured)
  forM items $ \item -> case item.launch.owner of
    External -> pure (FlowValues Nothing Nothing [])
    Hosted identity _ -> maybe (readFlowValues item) (renderCaptured item) (lookup identity bundles)

readCaptured :: (FlowStore :> es, Failure :> es)
  => FlowBundleId -> Eff es (Either [Diagnostic] FlowBundle)
readCaptured identity = catchError @OperationalFailure (readBundleDescription identity)
  (\_ problem -> pure (Left [operationalDiagnostic problem]))

renderCaptured :: DhallHandling :> es
  => FlowInstance -> Either [Diagnostic] FlowBundle -> Eff es FlowValues
renderCaptured item captured = case (item.launch.owner,captured) of
  (External,_) -> pure (FlowValues Nothing Nothing [])
  (_,Left problems) -> pure (FlowValues Nothing Nothing problems)
  (Hosted _ recipe,Right bundle) -> case [entry | entry <- bundle.closure, entry.declaration.recipe == recipe] of
    [entry] -> do
      input <- encodeValue (contractShape entry.inputContract) item.launch.request
      output <- case item.status of
        Finished (Completed value) -> fmap Just <$> encodeValue (contractShape entry.outputContract) value
        _ -> pure (Right Nothing)
      pure (FlowValues (either (const Nothing) Just input) (either (const Nothing) id output)
        (either id (const []) input ++ either id (const []) output))
    _ -> pure (FlowValues Nothing Nothing [errorDiagnostic "flow.bundle-entry" "Captured recipe is absent from its execution bundle"])
