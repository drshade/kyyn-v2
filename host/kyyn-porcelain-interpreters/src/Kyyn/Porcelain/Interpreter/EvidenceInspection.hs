{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvidenceInspection (runEvidenceInspection) where

import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence (EvidenceProblem(..), CurrentEvidence(..), evidenceProblemDiagnostic, captureEvidence)
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Porcelain.Capability.EvidenceInspection

runEvidenceInspection :: Store.EvidenceStore :> es => Eff (EvidenceInspection : es) a -> Eff es a
runEvidenceInspection = interpret $ \_ request -> case request of
  ListCurrentEvidence instanceRef producer payload -> do
    loaded <- Store.loadCurrentEvidence instanceRef producer payload
    pure (diagnostic (loaded >>= maybe (Left NotFetched) (Right . captureEvidence)))
  ReadCurrentEvidence instanceRef producer payload key -> do
    loaded <- Store.loadCurrentEvidence instanceRef producer payload
    pure (diagnostic (loaded >>= maybe (Left NotFetched)
      (\(CurrentEvidence snapshot items latest) -> Right (snapshot, latest, lookup key items))))
  where
    diagnostic :: Either EvidenceProblem b -> Either [Diagnostic] b
    diagnostic = either (Left . pure . evidenceProblemDiagnostic) Right
