{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedRecordDot, ScopedTypeVariables #-}
module Kyyn.Porcelain.Interpreter.FlowStore (runFlowStore) where

import Agentic.Aeson (fromAeson, toAeson)
import qualified Kyyn.Types.FlowStatus as View
import Kyyn.Domain.Contract (descriptionOf)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Porcelain.Protocol.EventBindings (resolveEventBinding)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedEvent(..))
import Data.Aeson (encode, eitherDecodeStrict')
import Control.Monad (forM, forM_, void, when, unless, join)
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as Lazy
import Data.List (find, sort)
import Data.Maybe (isNothing)
import Kyyn.Porcelain.Interpreter.FlowLocks (tryFlowAdapterLock)
import Kyyn.Porcelain.Interpreter.FlowJournal (tryFlowWriterLock)
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
import qualified Kyyn.Domain.FlowDispatch as Dispatch
import qualified Kyyn.Domain.FlowPolling as Polling
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
  result <- case operation of
    ClearInstances requested -> clearSelected requested
    RetryInstance identity -> readRetry identity
    _ -> transaction operation
  case operation of
    ClearInstances _ -> case result of Right _ -> sweepJournals; Left _ -> pure ()
    _ -> pure ()
  pure result
  where
    readRetry identity = transaction (ReadInstance identity) >>= \case
      Nothing -> pure (Left MissingInstance)
      Just _ -> fmap (maybe (Left (InvalidTransition "An event adapter is active; retry after it returns")) id)
        (tryFlowAdapterLock kb identity (raise (transaction (RetryInstance identity))))
    clearSelected requested = do
      catalog <- transaction ListInstances
      case Lifecycle.clearFinished requested catalog of
        Left problem -> pure (Left problem)
        Right ([],_) -> pure (Right [])
        Right (removed,_) -> do
          -- Freeze the candidate set: an empty request means all terminal
          -- instances, and more may finish while locks are acquired.
          -- Terminal status cannot reverse. Once an adapter probe succeeds,
          -- no later adapter owner may start a call for these instances.
          probes <- forM (sort removed) (\identity -> tryFlowAdapterLock kb identity (pure ()))
          if any isNothing probes
            then pure (Left (InvalidTransition "An event adapter is active; retry clear after it returns"))
            else fmap (maybe (Left (InvalidTransition "A journal writer is active; retry clear after it returns")) id)
              (lockJournals removed (sort removed))
    lockJournals :: [FlowInstanceId] -> [FlowInstanceId] -> Eff es (Maybe (Either FlowStoreProblem [FlowInstanceId]))
    lockJournals requested [] = Just <$> transaction (ClearInstances requested)
    lockJournals requested (identity:remaining) = do
      nested <- tryFlowWriterLock kb identity $ do
        result <- raise (lockJournals requested remaining)
        case result of
          Just (Right removed) | identity `elem` removed -> void clearCurrent
          _ -> pure ()
        pure result
      pure (join nested)
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
          BeginDispatch identity key -> case find ((== identity) . (.instanceId)) catalog of
            Nothing -> pure (Right False)
            Just current -> commit $ do
              (started,updated) <- Dispatch.beginDispatch key current
              pure (started,replace updated catalog)
          CompleteDispatch identity key value -> case find ((== identity) . (.instanceId)) catalog of
            Nothing -> pure (Right ())
            Just current -> commit $ do
              updated <- Dispatch.completeDispatch key value current
              pure ((),replace updated catalog)
          BlockDispatch identity key problems -> case find ((== identity) . (.instanceId)) catalog of
            Nothing -> pure (Right ())
            Just current -> commit $ do
              updated <- Dispatch.blockDispatch key problems current
              pure ((),replace updated catalog)
          BeginPoll identity key now interval -> case find ((== identity) . (.instanceId)) catalog of
            Nothing -> pure (Right False)
            Just current -> commit $ do
              (started,updated) <- Polling.beginPoll now interval key current
              pure (started,replace updated catalog)
          CompletePoll identity key arrivals cursor -> case find ((== identity) . (.instanceId)) catalog of
            Nothing -> pure (Right False)
            Just current -> commit $ do
              (queued,updated) <- Polling.completePoll key arrivals cursor current
              pure (queued,replace updated catalog)
          FailPoll identity key problems -> case find ((== identity) . (.instanceId)) catalog of
            Nothing -> pure (Right ())
            Just current -> commit $ do
              updated <- Polling.failPoll key problems current
              pure ((),replace updated catalog)
          ListInstances -> pure catalog
          ReadDescendant caller target -> pure (Lifecycle.requireDescendant caller target catalog)
          CancelDescendant caller target selected -> commit $ do
            _ <- Lifecycle.requireDescendant caller target catalog
            Lifecycle.parentAllowsStart (Just caller) catalog
            next <- Lifecycle.cancelTree target selected catalog >>= Lifecycle.deliverCompletions encodeOutcome
            item <- maybe (Left MissingInstance) Right (find ((== target) . (.instanceId)) next)
            pure (item,next)
          ReadInstance identity -> pure (find ((== identity) . (.instanceId)) catalog)
          StartInstance parent key launch -> case launch.owner of
            Hosted{} -> pure (Left (InvalidTransition "Hosted instances require a prepared execution bundle"))
            External -> start parent key launch (pure ())
          StartPreparedInstance _ (Just key) _ | reserved key -> pure (Left reservedProblem)
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
                      let InteractionBindings allowed _ = parentDefinition.bindings
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
          ReportFrontier identity reached -> do
            captured <- case find ((== identity) . (.instanceId)) catalog of
              Just current | Hosted bundleId recipe <- current.launch.owner -> loadBundle base bundleId >>= \case
                Left problems -> pure (Left (InvalidTransition (Text.intercalate "; " (map (.message) problems))))
                Right bundle -> pure $ case [entry | entry <- bundle.closure, entry.declaration.recipe == recipe] of
                  [entry] -> Right (bundleId,bundle,entry)
                  _ -> Left (InvalidTransition "Captured recipe is missing")
              _ -> pure (Left (InvalidTransition "Wait requires a captured hosted execution"))
            let validate (key,descriptor,kind) = do
                  initialDispatch <- case kind of
                    ReplyWait -> Right Nothing
                    EventWait reference -> do
                      (_,bundle,entry) <- captured
                      let refuse problems = Left (InvalidTransition (Text.intercalate "; " (map (.message) problems)))
                      unless (reference `elem` entry.declaration.bindings.events)
                        (Left (InvalidTransition ("Event " <> Text.pack (show reference) <> " is outside this instance's captured declarations")))
                      PreparedEvent _ _ _ _ _ _ _ dispatch <- either refuse Right (resolveEventBinding reference bundle.plugins)
                      Right (Just (maybe NotRequired (const Pending) dispatch))
                    ChildWait child expected -> do
                      (bundleId,bundle,_) <- captured
                      selected <- Lifecycle.requireDescendant identity child catalog
                      recipe <- case selected.launch.owner of
                        Hosted childBundle recipe | childBundle == bundleId -> Right recipe
                        _ -> Left (InvalidTransition "Child wait does not share its parent's captured bundle")
                      case [entry | entry <- bundle.closure, entry.declaration.recipe == recipe] of
                        [entry] | descriptionOf entry.outputContract == expected -> Right Nothing
                        _ -> Left (InvalidTransition "Child output contract mismatch")
                  pure (key,descriptor,kind,initialDispatch)
            commit $ do
              checkedFrontier <- traverse validate reached
              changed <- change identity (Lifecycle.frontier checkedFrontier)
              notify changed
          FinishInstance identity outcome -> commit (change identity (Lifecycle.finish outcome) >>= notify)
          BlockAttempt identity problems -> commit (change identity (Lifecycle.blockAttempt problems))
          RetryInstance identity -> commit (change identity Lifecycle.retry)
          BlockInstance identity problems -> commit (change identity (Lifecycle.block problems))
          CancelInstance identity selected -> commit $ do
            next <- Lifecycle.cancelTree identity selected catalog >>= Lifecycle.deliverCompletions encodeOutcome
            item <- maybe (Left MissingInstance) Right (find ((== identity) . (.instanceId)) next)
            pure (item,next)
          QueueDelivery _ (Just key) _ _ _ | reserved key -> pure (Left reservedProblem)
          QueueDelivery identity requestedKey wait origin value -> case find ((== identity) . (.instanceId)) catalog of
            Nothing -> pure (Left MissingInstance)
            Just current -> do
              delivery <- maybe (freshKey (map (.deliveryId) current.deliveries)) pure requestedKey
              commit $ do
                (updated,received) <- Lifecycle.enqueue delivery wait origin value current
                pure (received,replace updated catalog)
          ResolveDelivery identity delivery outcome -> commit (change identity (Lifecycle.resolve delivery outcome))
    reserved key = any (`Text.isPrefixOf` key) ["internal-","auto-"]
    reservedProblem = InvalidTransition "Keys beginning internal- or auto- are reserved for host-generated identities"
    notify (item,catalog) = do
      next <- Lifecycle.deliverCompletions encodeOutcome catalog
      selected <- maybe (Left MissingInstance) Right (find ((== item.instanceId) . (.instanceId)) next)
      pure (selected,next)
    encodeOutcome outcome = toAeson (View.encodeOutcome fromAeson (case outcome of
      Completed value -> View.Completed value
      Failed problems -> View.Failed problems
      Cancelled -> View.Cancelled))
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
