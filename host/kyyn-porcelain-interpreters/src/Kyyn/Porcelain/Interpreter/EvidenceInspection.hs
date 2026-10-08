{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvidenceInspection (runEvidenceInspection) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.ByteString as Bytes
import Data.Coerce (coerce)
import qualified Data.Text.Encoding as Text
import Numeric (showHex)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), EvidenceProblem(..), evidenceProblemDiagnostic)
import Kyyn.Domain.EvidenceIndex (EvidenceIndex(EvidenceIndex), EvidenceSelection(EvidenceSelection), indexCapture)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Git (TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.Plugin (PackageIdentity(..), ConnectorName(..), pluginNameText, manifestName, entryModule)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, inferValue)
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Plumbing.Capability.GuestCompilation.Types (guestSources, sourceIdentity)
import Kyyn.Plumbing.Protocol.Plugin (decodeManifest)
import Kyyn.Plumbing.Protocol.ConnectorConfig (decodeInstances)
import Kyyn.Porcelain.Capability.RootStore (rootLocation)
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Porcelain.Capability.EvidenceInspection

runEvidenceInspection :: (Git.Git :> es, DhallHandling :> es, Store.EvidenceStore :> es)
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
    let identity = PackageIdentity (concatMap (\b -> let digits = showHex b "" in replicate (2 - length digits) '0' ++ digits)
          (Bytes.unpack (sourceIdentity source)))
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
  ReadCurrentEvidence selection key -> runExceptT $ do
    loaded <- ExceptT (fmap diagnostic (Store.openCurrentEvidence selection))
    index@(EvidenceIndex snapshot latest payload _) <- maybe (throwE [evidenceProblemDiagnostic NotFetched]) pure loaded
    item <- ExceptT (fmap diagnostic (Store.readCapturedEvidence index key))
    pure (snapshot,latest,payload,item)

diagnostic :: Either EvidenceProblem a -> Either [Diagnostic] a
diagnostic = either (Left . pure . evidenceProblemDiagnostic) Right

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "evidence.selection") pure
