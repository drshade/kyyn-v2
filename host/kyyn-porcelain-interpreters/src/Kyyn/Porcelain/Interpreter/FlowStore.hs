{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedRecordDot, ScopedTypeVariables #-}
module Kyyn.Porcelain.Interpreter.FlowStore (runFlowStore) where

import Data.Aeson (encode, eitherDecodeStrict')
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as Lazy
import Data.List (find)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.FlowInstance
import qualified Kyyn.Domain.FlowLifecycle as Lifecycle
import Kyyn.Domain.KnowledgeBase (KnowledgeBase, knowledgeBaseScope)
import Kyyn.Domain.Path (scopePath, directoryScope, relativePath)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Plumbing.Capability.DocumentPersistence
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import Kyyn.Porcelain.Capability.FlowStore
import Kyyn.Porcelain.Protocol.FlowCatalog (catalogValue, parseCatalog)
import System.FilePath ((</>))

-- This lock covers short catalog transactions only. Guest execution holds its
-- separate instance journal lock; ingress and cancellation never acquire that lock.
runFlowStore :: forall es a. (DocumentPersistence :> es, FileSystem.FileSystem :> es, Failure :> es)
  => KnowledgeBase -> Eff (FlowStore : es) a -> Eff es a
runFlowStore kb = interpret $ \_ operation -> do
  base <- checked (knowledgeBaseScope kb)
  scope <- checked (directoryScope (scopePath base </> ".kyyn/flows/catalog"))
  file <- checked (relativePath "instances.json")
  ignored <- checked (relativePath ".kyyn")
  FileSystem.ensureIgnoredDirectory base ignored
  withLockedDocument scope file $ do
    catalog <- readCurrent >>= maybe (pure []) (checked . (>>= parseEither parseCatalog) . eitherDecodeStrict')
    let persist next = if next == catalog then pure () else replaceCurrent (Lazy.toStrict (encode (catalogValue next)))
        commit :: Either FlowStoreProblem (b,[FlowInstance]) -> Eff (DocumentAccess : es) (Either FlowStoreProblem b)
        commit result = case result of
          Left refused -> pure (Left refused)
          Right (value,next) -> persist next >> pure (Right value)
        change identity f = do
          current <- maybe (Left MissingInstance) Right (find ((== identity) . (.instanceId)) catalog)
          updated <- f current
          pure (updated,replace updated catalog)
    case operation of
      ListInstances -> pure catalog
      ReadInstance identity -> pure (find ((== identity) . (.instanceId)) catalog)
      StartInstance parent key launch -> case find (\item -> item.parent == parent && item.startKey == key) catalog of
        Just old | old.launch == launch -> pure (Right old)
                 | otherwise -> pure (Left StartConflict)
        Nothing -> case Lifecycle.parentAllowsStart parent catalog of
          Left refused -> pure (Left refused)
          Right () -> do
            stamp <- freshStamp
            identity <- checked (flowInstanceId (Text.pack stamp.identity))
            let item = FlowInstance identity parent key launch Runnable [] False [] []
            commit (Right (item,catalog ++ [item]))
      BeginAttempt identity -> commit (change identity Lifecycle.begin)
      ReportFrontier identity reached -> commit (change identity (Lifecycle.frontier reached))
      FinishInstance identity outcome -> commit (change identity (Lifecycle.finish outcome))
      BlockInstance identity problems -> commit (change identity (Lifecycle.block problems))
      CancelInstance identity selected -> commit $ do
        next <- Lifecycle.cancelTree identity selected catalog
        item <- maybe (Left MissingInstance) Right (find ((== identity) . (.instanceId)) next)
        pure (item,next)
      QueueDelivery identity delivery wait origin value -> commit $ do
        current <- maybe (Left MissingInstance) Right (find ((== identity) . (.instanceId)) catalog)
        (updated,received) <- Lifecycle.enqueue delivery wait origin value current
        pure (received,replace updated catalog)
      ResolveDelivery identity delivery outcome -> commit (change identity (Lifecycle.resolve delivery outcome))
  where
    checked :: Failure :> effects => Either String b -> Eff effects b
    checked = either (\message -> raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.InspectEntry
      (either id scopePath (knowledgeBaseScope kb) </> ".kyyn/flows/catalog/instances.json") message))) pure
    replace updated = map (\old -> if old.instanceId == updated.instanceId then updated else old)
