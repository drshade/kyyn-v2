{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedRecordDot, ScopedTypeVariables #-}
module Kyyn.Porcelain.Interpreter.FlowStore (runFlowStore) where

import Data.Aeson (encode, eitherDecodeStrict')
import Control.Monad (forM_, void, when, unless)
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as Lazy
import Data.List (find)
import qualified Data.Text as Text
import Effectful (Eff, (:>), raise)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.FlowBundleId
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.CompiledProgram (CompiledProgram(..), BuildIdentity(..))
import Kyyn.Domain.Git (revisionName)
import Kyyn.Types.KnowledgeBase (InteractionBindings(..), ChildReference(..))
import Kyyn.Domain.FlowClosure (FlowDeclaration(..))
import Kyyn.Porcelain.Capability.FlowPreparation (PreparedFlow(..), FlowBundle(..), PreparedFlowEntry(..))
import Kyyn.Porcelain.Protocol.FlowBundle (bundleValue, parseBundle)
import Kyyn.Domain.FlowInstance
import qualified Kyyn.Domain.FlowLifecycle as Lifecycle
import Kyyn.Domain.KnowledgeBase (KnowledgeBase, knowledgeBaseScope)
import Kyyn.Domain.Path (scopePath, directoryScope, relativePath, relativeName)
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
  result <- transaction operation
  case operation of
    ClearInstances _ -> case result of Right _ -> sweepJournals; Left _ -> pure ()
    _ -> pure ()
  pure result
  where
    transaction :: FlowStore m b -> Eff es b
    transaction operation = do
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
            freshKey existing = do
              stamp <- freshStamp
              let key = Text.pack ("auto-" ++ stamp.identity)
              if key `elem` existing then freshKey existing else pure key
            start parent key launch beforeCommit = case find (\item -> item.parent == parent && item.startKey == key) catalog of
              Just old | old.launch == launch -> pure (Right old)
                       | otherwise -> pure (Left StartConflict)
              Nothing -> case Lifecycle.parentAllowsStart parent catalog of
                Left refused -> pure (Left refused)
                Right () -> do
                  let fresh = do
                        stamp <- freshStamp
                        candidate <- checked (flowInstanceId (Text.pack stamp.identity))
                        journalPath <- checked (relativePath (".kyyn/flows/journals/" ++ Text.unpack (flowInstanceIdText candidate)))
                        orphan <- FileSystem.entryExists base journalPath
                        if orphan || any ((== candidate) . (.instanceId)) catalog then fresh else pure candidate
                  identity <- fresh
                  beforeCommit
                  let item = FlowInstance identity parent key launch Runnable [] False False [] [] []
                  commit (Right (item,catalog ++ [item]))
        case operation of
          ListInstances -> pure catalog
          ReadDescendant caller target -> pure (Lifecycle.requireDescendant caller target catalog)
          CancelDescendant caller target selected -> commit $ do
            _ <- Lifecycle.requireDescendant caller target catalog
            Lifecycle.parentAllowsStart (Just caller) catalog
            next <- Lifecycle.cancelTree target selected catalog
            item <- maybe (Left MissingInstance) Right (find ((== target) . (.instanceId)) next)
            pure (item,next)
          ReadInstance identity -> pure (find ((== identity) . (.instanceId)) catalog)
          StartInstance parent key launch -> case launch.owner of
            Hosted{} -> pure (Left (InvalidTransition "Hosted instances require a prepared execution bundle"))
            External -> start parent key launch (pure ())
          StartPreparedInstance parent requestedKey prepared -> do
            key <- maybe (freshKey [item.startKey | item <- catalog, item.parent == parent]) pure requestedKey
            let bytes = Lazy.toStrict (encode (bundleValue prepared.bundle))
                identity = identifyBundle bytes
                launch = FlowLaunch (Text.pack (revisionName prepared.bundle.revision)) prepared.request
                  (Hosted identity prepared.selected)
            let authority = do
                  selected <- case [flow.declaration | flow <- prepared.bundle.closure, flow.declaration.recipe == prepared.selected] of
                    [definition] -> Right definition
                    _ -> Left (InvalidTransition "Selected recipe is not in the captured execution bundle")
                  case parent of
                    Nothing -> Right ()
                    Just parentId -> do
                      current <- maybe (Left MissingInstance) Right (find ((== parentId) . (.instanceId)) catalog)
                      (parentBundle,parentRecipe) <- case current.launch.owner of
                        Hosted bundle recipe -> Right (bundle,recipe)
                        External -> Left (InvalidTransition "Parent has no captured execution")
                      unless (parentBundle == identity) (Left (InvalidTransition "Child must use the parent's captured execution bundle"))
                      parentDefinition <- case [flow.declaration | flow <- prepared.bundle.closure, flow.declaration.recipe == parentRecipe] of
                        [definition] -> Right definition
                        _ -> Left (InvalidTransition "Parent is missing from its captured execution bundle")
                      let InteractionBindings allowed = parentDefinition.bindings
                      unless (ChildReference selected.recipe selected.entry `elem` allowed)
                        (Left (InvalidTransition "Child is outside the parent's declared child set"))
            case authority of
              Left refused -> pure (Left refused)
              Right () -> start parent key launch $ do
                path <- checked (relativePath (".kyyn/flows/bundles/" ++ flowBundleIdText identity ++ ".json"))
                existing <- FileSystem.readOptionalBytes base path
                case existing of
                  Nothing -> FileSystem.replaceBytes base path bytes
                  Just previous | previous == bytes -> pure ()
                                | otherwise -> problemAt (scopePath base </> relativeName path) "Execution bundle contents do not match their identity"
          ReadBundleDescription identity -> loadBundle base identity
          ReadExecutionBundle identity -> loadBundle base identity >>= \case
                Left problems -> pure (Left problems)
                Right bundle -> do
                  output <- checked (directoryScope bundle.program.identity.outputPath)
                  retained <- checked (directoryScope bundle.program.retentionRoot)
                  executable <- checked (relativePath "bin/kyyn-guest")
                  size <- FileSystem.fileSize output executable
                  retainedSize <- FileSystem.fileSize retained executable
                  resolved <- FileSystem.resolveDirectory retained
                  pure $ if size == Nothing || retainedSize == Nothing
                    then bundleProblem "flow.build-unavailable" "The captured guest build or its retention link is missing"
                    else if resolved /= Just output
                      then bundleProblem "flow.build-mismatch" "The retention link does not resolve to the captured guest output"
                      else Right bundle
          ClearInstances requested -> case Lifecycle.clearFinished requested catalog of
            Left refused -> pure (Left refused)
            Right (removed,remaining) -> do
              persist remaining
              directory <- checked (directoryScope (scopePath base </> ".kyyn/flows/bundles"))
              candidates <- FileSystem.listDirectory directory
              let referenced = [identity | item <- remaining, Hosted identity _ <- [item.launch.owner]]
              forM_ (maybe [] id candidates) $ \candidate ->
                case Text.stripSuffix ".json" (Text.pack (relativeName candidate)) >>= either (const Nothing) Just . flowBundleId . Text.unpack of
                  Just identity | identity `notElem` referenced -> FileSystem.removeFile directory candidate
                  _ -> pure ()
              pure (Right removed)
          LinkAttempt identity attempt -> commit (change identity (\item -> case item.status of
            Running -> Right item { attempts = if attempt `elem` item.attempts then item.attempts else item.attempts ++ [attempt] }
            Finished{} -> Left AlreadyFinished
            _ -> Left (InvalidTransition "Attempt recording requires a running instance")))
          BeginAttempt identity -> commit (change identity Lifecycle.begin)
          ReportFrontier identity reached -> commit (change identity (Lifecycle.frontier reached))
          FinishInstance identity outcome -> commit (change identity (Lifecycle.finish outcome))
          BlockAttempt identity problems -> commit (change identity (Lifecycle.blockAttempt problems))
          RetryInstance identity -> commit (change identity Lifecycle.retry)
          BlockInstance identity problems -> commit (change identity (Lifecycle.block problems))
          CancelInstance identity selected -> commit $ do
            next <- Lifecycle.cancelTree identity selected catalog
            item <- maybe (Left MissingInstance) Right (find ((== identity) . (.instanceId)) next)
            pure (item,next)
          QueueDelivery identity requestedKey wait origin value -> case find ((== identity) . (.instanceId)) catalog of
            Nothing -> pure (Left MissingInstance)
            Just current -> do
              delivery <- maybe (freshKey (map (.deliveryId) current.deliveries)) pure requestedKey
              commit $ do
                (updated,received) <- Lifecycle.enqueue delivery wait origin value current
                pure (received,replace updated catalog)
          ResolveDelivery identity delivery outcome -> commit (change identity (Lifecycle.resolve delivery outcome))
    loadBundle base identity = do
      path <- checked (relativePath (".kyyn/flows/bundles/" ++ flowBundleIdText identity ++ ".json"))
      stored <- FileSystem.readOptionalBytes base path
      case stored of
        Nothing -> pure (bundleProblem "flow.bundle-missing" "Captured execution bundle is missing")
        Just bytes | identifyBundle bytes /= identity -> pure (bundleProblem "flow.bundle-identity" "Captured execution bundle identity differs from its contents")
        Just bytes -> case eitherDecodeStrict' bytes >>= parseEither parseBundle of
          Left message -> pure (bundleProblem "flow.bundle-invalid" message)
          Right bundle -> pure (Right bundle)
    -- Lock order matches the worker: journal first, then the short catalog lock.
    -- Recheck catalog membership under that lock before deleting an orphan.
    sweepJournals = do
      base <- checked (knowledgeBaseScope kb)
      journals <- checked (directoryScope (scopePath base </> ".kyyn/flows/journals"))
      candidates <- FileSystem.listDirectory journals
      catalogScope <- checked (directoryScope (scopePath base </> ".kyyn/flows/catalog"))
      catalogFile <- checked (relativePath "instances.json")
      present <- withLockedDocument catalogScope catalogFile $ do
        catalog <- readCurrent >>= maybe (pure []) (checked . (>>= parseEither parseCatalog) . eitherDecodeStrict')
        pure (map (.instanceId) catalog)
      forM_ (maybe [] id candidates) $ \candidate -> case flowInstanceId (Text.pack (relativeName candidate)) of
        Left _ -> pure ()
        Right identity | identity `elem` present -> pure ()
        Right identity -> do
          journal <- checked (directoryScope (scopePath journals </> relativeName candidate))
          file <- checked (relativePath "journal.json")
          withLockedDocument journal file $ do
            withLockedDocument catalogScope catalogFile $ do
              catalog <- readCurrent >>= maybe (pure []) (checked . (>>= parseEither parseCatalog) . eitherDecodeStrict')
              when (all ((/= identity) . (.instanceId)) catalog)
                (void (raise (clearCurrent :: Eff (DocumentAccess : es) Bool)))
    bundleProblem code message = Left [errorDiagnostic code message]
    problemAt :: Failure :> effects => FilePath -> String -> Eff effects b
    problemAt path message = raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.InspectEntry path message))
    checked :: Failure :> effects => Either String b -> Eff effects b
    checked = either (\message -> raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.InspectEntry
      (either id scopePath (knowledgeBaseScope kb) </> ".kyyn/flows/catalog/instances.json") message))) pure
    replace updated = map (\old -> if old.instanceId == updated.instanceId then updated else old)
