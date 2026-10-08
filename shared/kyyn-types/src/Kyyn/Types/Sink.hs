{-# LANGUAGE GADTs #-}
module Kyyn.Types.Sink (SinkError(..), FileWrite(..), SinkCalls) where

import Data.Text (Text)

data SinkError = SinkRejected Text | SinkUncertain Text deriving (Eq, Show)
data FileWrite a where
  WriteTextFile :: FilePath -> Text -> FileWrite (Either SinkError FilePath)
type SinkCalls = FileWrite
