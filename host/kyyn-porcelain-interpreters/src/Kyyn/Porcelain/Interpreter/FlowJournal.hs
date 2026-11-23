{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedRecordDot, ScopedTypeVariables, RankNTypes, TypeApplications #-}
module Kyyn.Porcelain.Interpreter.FlowJournal (runFlowJournal, runFlowJournalLocked, tryFlowWriterLock) where

import Control.Monad (unless)
import Data.Aeson (Value, encode, eitherDecodeStrict', object, (.=), (.:), withObject)
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString.Lazy as Lazy
import Data.ByteString (ByteString)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (nub, sort)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Kyyn.Domain.FlowInstance (FlowInstanceId, flowInstanceIdText)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase, knowledgeBaseScope)
import Kyyn.Domain.Path (scopePath, directoryScope, relativePath)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Plumbing.Capability.DocumentPersistence
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import Kyyn.Porcelain.Capability.FlowJournal
import System.FilePath ((</>))

-- A process-held document lock serialises a whole execution/fulfilment attempt.
-- Atomic replacement survives process restart; no machine-power-loss claim.
runFlowJournal :: forall es a. (DocumentPersistence :> es, FileSystem.FileSystem :> es, Failure :> es)
  => KnowledgeBase -> FlowJournalIdentity -> Eff (FlowJournal : es) a -> Eff es a
runFlowJournal kb expected action = do
  let name = Text.unpack expected.namespace
      valid c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '-' || c == '_'
  unless (not (null name) && all valid name) (problem (JournalCorrupt "Invalid flow journal namespace"))
  kbScope <- either (problem . JournalCorrupt . Text.pack) pure (knowledgeBaseScope kb)
  let directory = scopePath kbScope </> ".kyyn/flows/journals" </> name
  scope <- either (problem . JournalCorrupt . Text.pack) pure (directoryScope directory)
  file <- either (problem . JournalCorrupt . Text.pack) pure (relativePath "journal.json")
  ignored <- either (problem . JournalCorrupt . Text.pack) pure (relativePath ".kyyn")
  FileSystem.ensureIgnoredDirectory kbScope ignored
  reinterpret (\inside -> withLockedDocument scope file (initialise problem expected inside))
    (\_ -> handleJournal problem expected) action
  where
    problem :: Failure :> effects => FlowJournalProblem -> Eff effects b
    problem issue = raiseFailure (Failure.StorageUnavailable
      (Failure.StorageDiagnostic Failure.InspectEntry
        (either id scopePath (knowledgeBaseScope kb) </> ".kyyn/flows/journals" </> Text.unpack expected.namespace </> "journal.json") (show issue)))

-- Shared nonblocking lock for execution and read-only activity probes. A probe
-- passes pure (), and never initializes a journal or evaluates guest code.
-- A worker may lose this instant try-lock race and skip a pass: keep inspection
-- critical sections empty so probing never turns into an execution delay.
tryFlowWriterLock :: (DocumentPersistence :> es, Failure :> es)
  => KnowledgeBase -> FlowInstanceId -> Eff (DocumentAccess : es) a -> Eff es (Maybe a)
tryFlowWriterLock kb identity action = do
  base <- checked (knowledgeBaseScope kb)
  directory <- checked (directoryScope (scopePath base </> ".kyyn/flows/journals" </> Text.unpack (flowInstanceIdText identity)))
  file <- checked (relativePath "journal.json")
  tryLockedDocument directory file action
  where
    checked = either (raiseFailure . Failure.StorageUnavailable . Failure.StorageDiagnostic Failure.InspectEntry ".kyyn/flows") pure

-- The worker acquires a nonblocking writer lock, rechecks the catalog while
-- holding it, then installs this interpreter. Inspection probes never call it.
runFlowJournalLocked :: DocumentAccess :> es
  => FlowJournalIdentity -> Eff (FlowJournal : es) a -> Eff es (Either FlowJournalProblem a)
runFlowJournalLocked expected = reinterpret
  (runErrorNoCallStack @FlowJournalProblem . initialise throwError expected)
  (\_ -> handleJournal throwError expected)

initialise :: DocumentAccess :> es
  => (forall b. FlowJournalProblem -> Eff es b) -> FlowJournalIdentity -> Eff es a -> Eff es a
initialise problem expected inside = do
  existing <- readCurrent
  case existing of
    Nothing -> replaceCurrent (serialise expected [])
    Just bytes -> do
      (actual,_) <- either (problem . JournalCorrupt . Text.pack) pure (decode bytes)
      unless (actual == expected) (problem JournalIdentityMismatch)
  inside

handleJournal :: DocumentAccess :> es
  => (forall b. FlowJournalProblem -> Eff es b) -> FlowJournalIdentity -> FlowJournal m a -> Eff es a
handleJournal problem expected = \case
  LookupCompletion key -> lookup key <$> records
  SaveCompletion key value -> do
    entries <- records
    case lookup key entries of
      Just old | old == value -> pure ()
               | otherwise -> problem JournalCompletionConflict
      Nothing -> replaceCurrent (serialise expected (entries ++ [(key,value)]))
  where
    records = readCurrent >>= \case
      Nothing -> problem (JournalCorrupt "Flow journal disappeared during execution")
      Just bytes -> snd <$> either (problem . JournalCorrupt . Text.pack) pure (decode bytes)

decode :: ByteString -> Either String (FlowJournalIdentity,[(Value,Value)])
decode bytes = eitherDecodeStrict' bytes >>= parseEither document

serialise :: FlowJournalIdentity -> [(Value,Value)] -> ByteString
serialise identity entries = Lazy.toStrict (encode (object
  ["namespace" .= identity.namespace,"revision" .= identity.revision,"input" .= identity.input,
   "completions" .= [object ["key" .= key,"value" .= value] | (key,value) <- entries]]))

document :: Value -> Parser (FlowJournalIdentity,[(Value,Value)])
document = withObject "flow journal" $ \fields -> do
  unless (sort (Keys.keys fields) == ["completions","input","namespace","revision"])
    (fail "Unexpected or missing flow journal fields")
  identity <- FlowJournalIdentity <$> fields .: "namespace" <*> fields .: "revision" <*> fields .: "input"
  values <- fields .: "completions"
  entries <- traverse (withObject "completion" (\entry -> do
    unless (sort (Keys.keys entry) == ["key","value"]) (fail "Unexpected completion fields")
    (,) <$> entry .: "key" <*> entry .: "value")) values
  unless (length (nub (map fst entries)) == length entries) (fail "Duplicate completion keys")
  pure (identity,entries)
