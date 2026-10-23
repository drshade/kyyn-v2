{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Directory (fetch) where
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad.Trans.Class (lift)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import Kyyn.Validation
import MicrosoftGraph.Config (graphApiBase)
import MicrosoftGraph.Directory.Types
import MicrosoftGraph.Directory.Fingerprint (canonicalDirectory)
import qualified MicrosoftGraph.Directory.Config as Config
import qualified MicrosoftGraph.Directory.Api as Api
import qualified MicrosoftGraph.Auth as Auth

fetch :: DirectoryConfig -> EvidenceSnapshot DirectoryPayload -> Acquisition DirectoryPayload (Either FetchError [EvidenceChange DirectoryPayload])
fetch config@(DirectoryConfig auth) snapshot = fmap (either (Left . FetchError) Right) $ runExceptT $ do
  case Config.validate config of
    ValidationReport [] -> pure ()
    ValidationReport (Diagnostic _ _ message _:_) -> throwE message
  token <- ExceptT (Auth.accessToken auth)
  payload <- DirectoryPayload <$> ExceptT (Api.listing token)
  digests <- lift (digestText [canonicalDirectory payload])
  digest <- case digests of [value] -> pure value; _ -> throwE "Host returned the wrong number of directory digests"
  old <- ExceptT (fmap (either (\(FetchError message) -> Left message) Right) (readEvidence snapshot (EvidenceId "directory")))
  let key = EvidenceId "directory"
      fingerprint = EvidenceFingerprint digest
      available = Available payload
      evidence = Evidence fingerprint [graphApiBase <> "users"] available
  pure $ case old of
    Nothing -> [NewEvidence key evidence]
    Just (Evidence previous _ state)
      | previous /= fingerprint -> [UpdatedEvidence key evidence]
      | otherwise -> case state of
          Truncated -> [SetEvidencePayload key fingerprint available]
          Available _ -> []
