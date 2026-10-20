{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Files (fetch) where
import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad.Trans.Class (lift)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin
import Kyyn.Plugin.Host
import Kyyn.Validation
import MicrosoftGraph.Files.Types
import qualified MicrosoftGraph.Files.Config as Config
import qualified MicrosoftGraph.Files.Api as Api
import qualified MicrosoftGraph.Auth as Auth
import qualified MicrosoftGraph.Json as Json
import qualified MicrosoftGraph.Http as Http
import Text.JSON.Types (JSValue(..))

fetch :: FilesConfig -> EvidenceSnapshot FilePayload -> Acquisition FilePayload (Either FetchError [EvidenceChange FilePayload])
fetch config@(FilesConfig auth _ _ _) snapshot = fmap (either (Left . FetchError) Right) $ runExceptT $ do
  case Config.validate config of
    ValidationReport [] -> pure ()
    ValidationReport (Diagnostic _ _ message _:_) -> throwE message
  token <- ExceptT (Auth.accessToken auth)
  rows <- ExceptT (Api.listing token config)
  captured <- forM rows $ \(identity,drive,path,value) -> do
    old <- ExceptT (fmap failure (readEvidence snapshot (EvidenceId identity)))
    key <- either throwE pure (Api.field "id" value)
    name <- either throwE pure (Api.field "name" value)
    url <- either throwE pure (Api.field "webUrl" value)
    media <- either throwE pure (Json.member "file" value >>= Api.field "mimeType")
    size <- either throwE pure (Json.member "size" value >>= Json.integer)
    modified <- either throwE pure (Api.field "lastModifiedDateTime" value)
    modifier <- either throwE pure (modifierName value)
    tag <- either throwE pure (Json.optionalText "cTag" value)
    let usableTag = case tag of Just "" -> Nothing; _ -> tag
        previous = case old of
          Just (Evidence _ _ (Available (FilePayload _ _ _ _ oldSize _ _ oldTag blob)))
            | usableTag /= Nothing && oldTag == usableTag && oldSize == toInteger size -> Just blob
          _ -> Nothing
    BlobRef digest actualSize _ _ <- case previous of
      Just blob -> pure blob
      Nothing -> ExceptT (Http.download (BlobDownload
        (HttpRequest "GET" (Api.itemUrl drive key <> "/content") [("Authorization","Bearer " <> token)] "")
        (Just name) (Just media)))
    if actualSize /= toInteger size then throwE "Graph file size changed during capture; retry the fetch" else pure ()
    let blob = BlobRef digest actualSize media (Just name)
        payload = FilePayload name path url media actualSize modified modifier usableTag blob
    pure (EvidenceId identity,old,payload)
  digests <- lift (digestText [Text.pack (show payload) | (_,_,payload) <- captured])
  if length digests /= length captured then throwE "Host returned the wrong number of file digests" else pure ()
  oldKeys <- ExceptT (fmap failure (listEvidenceIds snapshot))
  let changes = concat [changed key old (Evidence (EvidenceFingerprint digest) [url] (Available payload))
        | ((key,old,payload@(FilePayload _ _ url _ _ _ _ _ _)),digest) <- zip captured digests]
      keys = [key | (EvidenceId key,_,_) <- captured]
  pure (changes ++ removed (sort [key | EvidenceId key <- oldKeys]) keys)
  where
    failure = either (\(FetchError message) -> Left message) Right

modifierName :: JSValue -> Either Text Text
modifierName value = case Api.optional "lastModifiedBy" value of
  JSNull -> Right ""
  actor -> case Api.optional "user" actor of
    JSNull -> case Api.optional "application" actor of
      JSNull -> case Api.optional "device" actor of
        JSNull -> Right ""
        device -> maybe "" id <$> Json.optionalText "displayName" device
      application -> maybe "" id <$> Json.optionalText "displayName" application
    user -> maybe "" id <$> Json.optionalText "displayName" user

changed :: EvidenceId -> Maybe (Evidence FilePayload) -> Evidence FilePayload -> [EvidenceChange FilePayload]
changed key Nothing value = [NewEvidence key value]
changed key (Just (Evidence previous _ Truncated)) (Evidence current _ payload)
  | previous == current = [SetEvidencePayload key current payload]
changed key (Just (Evidence previous _ _)) value@(Evidence current _ _)
  | previous == current = []
  | otherwise = [UpdatedEvidence key value]

removed :: [Text] -> [Text] -> [EvidenceChange FilePayload]
removed [] _ = []
removed old [] = map (RemovedEvidence . EvidenceId) old
removed old@(key:rest) current@(next:remaining) = case compare key next of
  LT -> RemovedEvidence (EvidenceId key) : removed rest current
  EQ -> removed rest remaining
  GT -> removed old remaining
