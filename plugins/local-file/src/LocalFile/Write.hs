{-# LANGUAGE OverloadedStrings #-}
module LocalFile.Write (Config(..), Options(..), defaults, validate, publish) where

import Data.Text (Text)
import Kyyn.Plugin.Sink (Sink, SinkError(..), writeTextFile)
import Kyyn.Validation

-- | Write a UTF-8 document relative to the KB, or to an absolute path.
data Config = Config { path :: FilePath } deriving (Eq, Show)

-- | Optionally choose a different destination for this publication.
data Options = Options { pathOverride :: Maybe FilePath } deriving (Eq, Show)

defaults :: Options
defaults = Options Nothing

validate :: Config -> ValidationReport
validate (Config path) = ValidationReport
  [errorDiagnostic "local-file.path" "Destination must be nonempty and contain no NUL" | invalid path]

publish :: Config -> Options -> Text -> Sink (Either SinkError FilePath)
publish (Config configured) (Options override) content
  | invalid destination = pure (Left (SinkRejected "Destination must be nonempty and contain no NUL"))
  | otherwise = writeTextFile destination content
  where destination = maybe configured id override

invalid :: FilePath -> Bool
invalid path = null path || '\0' `elem` path
