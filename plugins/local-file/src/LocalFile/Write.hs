module LocalFile.Write (Config(..), Options(..), defaults, validate, publish) where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)

import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin.Sink (Sink, SinkError(..), writeTextFile)
import Kyyn.Validation

-- | Write a UTF-8 document relative to the KB, or to an absolute path.
data Config = Config { path :: Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

-- | Optionally choose a different destination for this publication.
data Options = Options { pathOverride :: Maybe Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

defaults :: Options
defaults = Options Nothing

validate :: Config -> ValidationReport
validate (Config path) = ValidationReport
  [errorDiagnostic "local-file.path" "Destination must be nonempty and contain no NUL" | invalid path]

publish :: Config -> Options -> Text -> Sink (Either SinkError Text)
publish (Config configured) (Options override) content
  | invalid destination = pure (Left (SinkRejected "Destination must be nonempty and contain no NUL"))
  | otherwise = writeTextFile destination content
  where destination = maybe configured id override

invalid :: Text -> Bool
invalid path = Text.null path || Text.any (== '\0') path
