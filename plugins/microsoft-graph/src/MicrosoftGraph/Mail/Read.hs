{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Mail.Read (message, body, attachments) where
import Data.Text (Text)
import Kyyn.Plugin
import MicrosoftGraph.Mail.Types (Message, Attachment)
import qualified MicrosoftGraph.Mail.Types as Schema

message :: Text -> EvidenceSnapshot Message -> CapturedRead Message (Either FetchError Message)
message key snapshot = do
  found <- readEvidence snapshot (EvidenceId key)
  pure $ case found of
    Left problem -> Left problem
    Right Nothing -> Left (FetchError "No captured message with that ID")
    Right (Just (Evidence _ _ Truncated)) -> Left (FetchError "Message payload has been truncated")
    Right (Just (Evidence _ _ (Available value))) -> Right value

body :: Text -> EvidenceSnapshot Message -> CapturedRead Message (Either FetchError Text)
body key snapshot = fmap (fmap (\Schema.Message { Schema.body = text } -> text)) (message key snapshot)

attachments :: Text -> EvidenceSnapshot Message -> CapturedRead Message (Either FetchError [Attachment])
attachments key snapshot = fmap (fmap (\Schema.Message { Schema.attachments = values } -> values)) (message key snapshot)
