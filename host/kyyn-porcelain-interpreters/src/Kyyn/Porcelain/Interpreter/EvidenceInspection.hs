{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvidenceInspection (runEvidenceInspection) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence (EvidenceProblem, evidenceProblemDiagnostic, summarizeFetch)
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Porcelain.Capability.EvidenceInspection

runEvidenceInspection :: Store.EvidenceStore :> es => Eff (EvidenceInspection : es) a -> Eff es a
runEvidenceInspection = interpret $ \_ request -> case request of
  FetchHistory instanceRef producer payload selection -> runExceptT $ do
    snapshot <- ExceptT (fmap diagnostic (Store.selectEvidence instanceRef producer selection))
    fetches <- ExceptT (fmap diagnostic (Store.readFetchesBetween snapshot payload Nothing))
    pure (snapshot,map summarizeFetch fetches)
  EvidenceChanges instanceRef producer payload selection since -> runExceptT $ do
    snapshot <- ExceptT (fmap diagnostic (Store.selectEvidence instanceRef producer selection))
    changes <- ExceptT (fmap diagnostic (Store.listEvidenceChanges snapshot payload since))
    pure (snapshot,changes)
  where
    diagnostic :: Either EvidenceProblem b -> Either [Diagnostic] b
    diagnostic = either (Left . pure . evidenceProblemDiagnostic) Right
