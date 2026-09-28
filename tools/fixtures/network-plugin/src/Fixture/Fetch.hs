module Fixture.Fetch where
import Fixture.Types
import KyynPluginBindings
fetch :: Config -> EvidenceSnapshot Payload -> Acquisition (Either FetchError [EvidenceChange Payload])
fetch (Config endpoint key) snapshot = do
  secret <- getSecret key
  case secret of
    Left _ -> pure (Left (FetchError "Run connector login first"))
    Right token -> do
      response <- sendHttp (HttpRequest "GET" (endpoint ++ "/fetch") [("Authorization",token)] "")
      case response of
        Right (HttpResponse 200 _ contents) -> do
          previous <- readEvidence snapshot (EvidenceId "one")
          let evidence = Evidence (EvidenceFingerprint contents) [endpoint] contents
          pure $ case previous of
            Left problem -> Left problem
            Right Nothing -> Right [NewEvidence (EvidenceId "one") evidence]
            Right (Just old) | old == evidence -> Right []
                             | otherwise -> Right [UpdatedEvidence (EvidenceId "one") evidence]
        _ -> pure (Left (FetchError "Fixture fetch failed"))
