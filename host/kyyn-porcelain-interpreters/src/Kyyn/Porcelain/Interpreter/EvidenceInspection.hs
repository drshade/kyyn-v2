{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvidenceInspection (runEvidenceInspection) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Coerce (coerce)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Blob (ResolvedBlob(..), blobReferences)
import Kyyn.Domain.Contract (rootType)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Plugin (FetchError(..))
import qualified Data.Text as Text
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage, blobPathAt)
import Kyyn.Domain.EvidenceIndex (EvidenceIndex(EvidenceIndex), EvidenceSelection(EvidenceSelection), indexCapture)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Git (TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.Plugin (ConnectorName(..), pluginNameText, manifestName, entryModule)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, inferValue)
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Plumbing.Capability.GuestCompilation.Types (guestSources, packageIdentity)
import Kyyn.Plumbing.Protocol.Plugin (decodeManifest)
import Kyyn.Plumbing.Protocol.ConnectorConfig (decodeInstances)
import Kyyn.Porcelain.Capability.RootStore (rootLocation)
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Porcelain.Capability.EvidenceInspection

runEvidenceInspection :: (Git.Git :> es, DhallHandling :> es, Store.EvidenceStore :> es, BlobStorage :> es)
  => Eff (EvidenceInspection : es) a -> Eff es a
runEvidenceInspection = interpret $ \_ request -> case request of
  SelectEvidence kb@(KnowledgeBase repository _) revision plugin name -> runExceptT $ do
    root <- checked (rootLocation kb)
    let base = relativeName root ++ "/plugins/"
        label = pluginNameText plugin
    packagePath <- checked (relativePath (base ++ "packages/" ++ label ++ "/source"))
    tree <- ExceptT (Git.readTreeAt repository revision (Subtree packagePath))
    manifestPath <- checked (relativePath "kyyn-plugin.dhall")
    bytes <- maybe (throwE [errorDiagnostic "plugin.manifest-missing" "Installed plugin manifest is missing"]) pure
      (lookup manifestPath (files tree))
    manifest <- ExceptT (decodeManifest bytes)
    unless (manifestName manifest == plugin) (throwE [errorDiagnostic "plugin.manifest-name" "Installed plugin manifest name differs from its directory"])
    entry <- checked (relativePath ("src/" ++ map (\c -> if c == '.' then '/' else c) (entryModule manifest) ++ ".hs"))
    source <- checked (guestSources entry (files tree))
    let identity = packageIdentity source
    configPath <- checked (relativePath (base ++ "config/" ++ label ++ ".dhall"))
    configuration <- ExceptT (Git.readFileAt repository revision configPath) >>= maybe
      (throwE [errorDiagnostic "plugin.instance-unknown" "No instances configured for this plugin"]) pure
    text <- checked (either (Left . show) Right (Text.decodeUtf8' configuration))
    (_,value) <- ExceptT (inferValue text)
    instances <- checked (decodeInstances value)
    case [kind | (selected,_,kind,_) <- instances, selected == name] of
      [kind] -> pure (EvidenceSelection (ConnectorInstanceRef plugin (coerce name)) kind identity)
      _ -> throwE [errorDiagnostic "plugin.instance-unknown" "No configured instance with this name"]
  ListCurrentEvidence selection -> do
    loaded <- Store.openCurrentEvidence selection
    pure (diagnostic (loaded >>= maybe (Left NotFetched) (Right . indexCapture)))
  ReadEvidenceBatch selection expected -> runExceptT $ do
    loaded <- ExceptT (fmap diagnostic (Store.openCurrentEvidence selection))
    index@(EvidenceIndex snapshot@(EvidenceSnapshotRef instanceRef _ actual) latest payload _) <-
      maybe (throwE [evidenceProblemDiagnostic NotFetched]) pure loaded
    unless (maybe True (== actual) expected) $
      throwE [errorDiagnostic "evidence.fetch-mismatch" "Current evidence differs from --expect-fetch. Inspect the latest capture and retry."]
    let EvidenceCapture _ _ keys = indexCapture index
    entries <- mapM (\(key,_,_) -> do
      found <- ExceptT (fmap diagnostic (Store.readCapturedEvidence index key))
      item <- maybe (throwE [errorDiagnostic "evidence.invalid-data" "Item is missing from the selected capture."]) pure found
      refs <- case item of
        Evidence _ _ Truncated -> pure []
        Evidence _ _ (Available (CheckedValue _ value)) ->
          either (throwE . pure . errorDiagnostic "blob.reference") pure (blobReferences (rootType payload) value)
      paths <- mapM (\ref -> do
        path <- ExceptT (fmap (either (\(FetchError message) -> Left [errorDiagnostic "blob.unavailable" (Text.unpack message)]) Right)
          (blobPathAt instanceRef ref))
        pure (ResolvedBlob ref path)) refs
      pure (key,item,paths)) keys
    pure (EvidenceBatch snapshot latest entries)
  ReadCurrentEvidence selection key -> runExceptT $ do
    loaded <- ExceptT (fmap diagnostic (Store.openCurrentEvidence selection))
    index@(EvidenceIndex snapshot latest payload _) <- maybe (throwE [evidenceProblemDiagnostic NotFetched]) pure loaded
    item <- ExceptT (fmap diagnostic (Store.readCapturedEvidence index key))
    pure (snapshot,latest,payload,item)

diagnostic :: Either EvidenceProblem a -> Either [Diagnostic] a
diagnostic = either (Left . pure . evidenceProblemDiagnostic) Right

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "evidence.selection") pure
