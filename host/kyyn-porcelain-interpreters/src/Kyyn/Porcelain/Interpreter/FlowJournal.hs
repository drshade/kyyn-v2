{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedRecordDot, ScopedTypeVariables #-}
module Kyyn.Porcelain.Interpreter.FlowJournal (runFlowJournal) where

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
  unless (not (null name) && all valid name) (problem "Invalid flow journal namespace")
  kbScope <- either problem pure (knowledgeBaseScope kb)
  let directory = scopePath kbScope </> ".kyyn/flows" </> name
  scope <- either problem pure (directoryScope directory)
  file <- either problem pure (relativePath "journal.json")
  ignored <- either problem pure (relativePath ".kyyn")
  FileSystem.ensureIgnoredDirectory kbScope ignored
  reinterpret (\inside -> withLockedDocument scope file $ do
    existing <- readCurrent
    case existing of
      Nothing -> replaceCurrent (serialise expected [])
      Just bytes -> do
        (actual,_) <- either problem pure (decode bytes)
        unless (actual == expected) (problem "Flow journal revision or original input differs")
    inside)
    (\_ -> \case
      LookupCompletion key -> lookup key <$> records
      SaveCompletion key value -> do
        entries <- records
        case lookup key entries of
          Just old | old == value -> pure ()
                   | otherwise -> problem "Conflicting immutable flow completion"
          Nothing -> replaceCurrent (serialise expected (entries ++ [(key,value)]))) action
  where
    problem :: Failure :> effects => String -> Eff effects b
    problem message = raiseFailure (Failure.StorageUnavailable
      (Failure.StorageDiagnostic Failure.InspectEntry
        (either id scopePath (knowledgeBaseScope kb) </> ".kyyn/flows" </> Text.unpack expected.namespace </> "journal.json") message))
    records :: (DocumentAccess :> effects, Failure :> effects) => Eff effects [(Value,Value)]
    records = readCurrent >>= \case
      Nothing -> problem "Flow journal disappeared during execution"
      Just bytes -> snd <$> either problem pure (decode bytes)
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
