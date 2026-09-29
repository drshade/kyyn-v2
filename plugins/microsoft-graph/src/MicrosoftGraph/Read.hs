module MicrosoftGraph.Read (event) where
import KyynPluginBindings
import MicrosoftGraph.Types
event :: EventId -> EvidenceSnapshot Event -> CapturedRead (Either FetchError Event)
event key snapshot = do
  result <- readEvidence snapshot (EvidenceId key)
  pure $ case result of
    Left problem -> Left problem
    Right Nothing -> Left (FetchError ("No fetched event with ID " ++ key))
    Right (Just (Evidence _ _ value)) -> Right value
