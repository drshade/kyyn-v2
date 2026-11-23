module Kyyn.Porcelain.Interpreter.FlowLocks (tryFlowAdapterLock) where

import Effectful (Eff, (:>))
import qualified Data.Text as Text
import Kyyn.Domain.FlowInstance (FlowInstanceId, flowInstanceIdText)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase, knowledgeBaseScope)
import Kyyn.Domain.Path (scopePath, directoryScope, relativePath)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Plumbing.Capability.DocumentPersistence
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import System.FilePath ((</>))

-- Ownership is process-held, not a lease or persisted PID. No journal lock may
-- be acquired while this action runs. The catalog stores all adapter state.
tryFlowAdapterLock :: (DocumentPersistence :> es, Failure :> es)
  => KnowledgeBase -> FlowInstanceId -> Eff (DocumentAccess : es) a -> Eff es (Maybe a)
tryFlowAdapterLock kb identity action = do
  base <- checked (knowledgeBaseScope kb)
  directory <- checked (directoryScope (scopePath base </> ".kyyn/flows/adapters" </> Text.unpack (flowInstanceIdText identity)))
  file <- checked (relativePath "unused")
  tryLockedDocument directory file action
  where checked = either (raiseFailure . Failure.StorageUnavailable . Failure.StorageDiagnostic Failure.InspectEntry ".kyyn/flows/adapters") pure
