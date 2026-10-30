module Kyyn.Porcelain.Protocol.CapturedBlobs (resolveBlobs) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Blob (ResolvedBlob(..), blobReferences)
import Kyyn.Domain.Contract (CheckedContract, rootType)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (EvidenceSnapshotRef(..))
import Kyyn.Domain.EvidenceIndex (EvidenceIndex(..), indexBlobs)
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage, blobPathAt)
import Kyyn.Types.Plugin (FetchError(..))

resolveBlobs :: BlobStorage :> es => [EvidenceIndex] -> CheckedContract -> Value
  -> Eff es (Either [Diagnostic] [ResolvedBlob])
resolveBlobs contexts contract value = runExceptT $ do
    let parse = either (throwE . pure . errorDiagnostic "blob.reference") pure
    refs <- parse (blobReferences (rootType contract) value)
    if null refs then pure [] else do
      let origins = [(ref,instanceRef) | index@(EvidenceIndex (EvidenceSnapshotRef instanceRef _ _) _ _ _ _) <- contexts,
            ref <- indexBlobs index]
      mapM (\ref -> case lookup ref origins of
        Nothing -> throwE [errorDiagnostic "blob.unreachable" "Result contains a blob outside the captured evidence."]
        Just instanceRef -> do
          path <- ExceptT (fmap (either (\(FetchError message) -> Left [errorDiagnostic "blob.unavailable" (Text.unpack message)]) Right)
            (blobPathAt instanceRef ref))
          pure (ResolvedBlob ref path)) refs
