{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs, DuplicateRecordFields #-}
module Kyyn.Types.PluginHost
  ( HttpRequest(..), HttpResponse(..), HttpError(..), Http(..)
  , SecretError(..), Secrets(..), Waiting(..), LoginInteraction(..), LoginError(..)
  ) where

import Data.Text (Text)

-- | A text HTTP request. Headers and body may contain credentials.
data HttpRequest = HttpRequest
  { method :: Text, url :: Text, headers :: [(Text, Text)], body :: Text }
  deriving Eq

-- | A text HTTP response, including non-success statuses for the plugin to handle.
data HttpResponse = HttpResponse
  { status :: Int, headers :: [(Text, Text)], body :: Text }
  deriving Eq

-- | Transport failures contain no request or response values.
data HttpError = InvalidHttpRequest | HttpTimedOut | HttpConnectionFailed | HttpUnavailable | InvalidHttpResponse
  deriving (Eq, Show)

data Http a where
  SendHttp :: HttpRequest -> Http (Either HttpError HttpResponse)

data SecretError = SecretNotFound Text deriving (Eq, Show)

data Secrets a where
  GetSecret :: Text -> Secrets (Either SecretError Text)
  PutSecret :: Text -> Text -> Secrets ()

data Waiting a where
  WaitSeconds :: Int -> Waiting ()

data LoginInteraction a where
  DisplayInstructions :: Text -> LoginInteraction ()

newtype LoginError = LoginError Text deriving (Eq, Show)
