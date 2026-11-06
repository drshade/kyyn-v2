{-# LANGUAGE GADTs #-}
module Kyyn.Types.Sink (SinkError(..), FileWrite(..), SinkCalls) where

import Data.Text (Text)

data SinkError = SinkRejected Text | SinkUncertain Text deriving (Eq, Show)
data FileWrite a where
  WriteTextFile :: Text -> Text -> FileWrite (Either SinkError Text)
type SinkCalls = FileWrite
