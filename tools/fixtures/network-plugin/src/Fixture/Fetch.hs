{-# LANGUAGE OverloadedStrings #-}
module Fixture.Fetch where
import qualified Data.Text as Text
import Fixture.Types
import Kyyn.Plugin
import Kyyn.Plugin.Host
fetch :: Config -> EvidenceSnapshot Payload -> Acquisition Payload (Either FetchError [EvidenceChange Payload])
fetch (Config endpoint key localPath) snapshot = do
  secret <- getSecret key
  case secret of
    Left _ -> pure (Left (FetchError "Run connector login first"))
    Right token -> do
      response <- sendHttp (HttpRequest "GET" (endpoint <> "/fetch") [("Authorization",token)] "")
      case response of
        Right (HttpResponse 200 _ contents) -> do
          local <- readTextFile localPath
          case local of
            Left problem -> pure (Left problem)
            Right (CapturedText suffix _) -> do
              waitSeconds 0
              previous <- readEvidence snapshot (EvidenceId "one")
              let combined = contents <> suffix
                  evidence = Evidence (EvidenceFingerprint combined) [endpoint,Text.pack localPath] combined
              pure $ case previous of
                Left problem -> Left problem
                Right Nothing -> Right [NewEvidence (EvidenceId "one") evidence]
                Right (Just old) | old == evidence -> Right []
                                 | otherwise -> Right [UpdatedEvidence (EvidenceId "one") evidence]
        _ -> pure (Left (FetchError "Fixture fetch failed"))
