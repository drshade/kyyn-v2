{-# LANGUAGE GADTs, DuplicateRecordFields #-}
module Kyyn.Types.PluginHost
  ( HttpRequest(..), HttpResponse(..), HttpError(..), Http(..)
  , SecretError(..), Secrets(..), Waiting(..), LoginInteraction(..)
  ) where

-- | A text HTTP request. Headers and body may contain credentials.
data HttpRequest = HttpRequest
  { method :: String, url :: String, headers :: [(String, String)], body :: String }
  deriving Eq

-- | A text HTTP response, including non-success statuses for the plugin to handle.
data HttpResponse = HttpResponse
  { status :: Int, headers :: [(String, String)], body :: String }
  deriving Eq

-- | Transport failures contain no request or response values.
data HttpError = InvalidHttpRequest | HttpUnavailable | InvalidHttpResponse
  deriving (Eq, Show)

data Http a where
  SendHttp :: HttpRequest -> Http (Either HttpError HttpResponse)

data SecretError = SecretNotFound String deriving (Eq, Show)

data Secrets a where
  GetSecret :: String -> Secrets (Either SecretError String)
  PutSecret :: String -> String -> Secrets ()

data Waiting a where
  WaitSeconds :: Int -> Waiting ()

data LoginInteraction a where
  DisplayInstructions :: String -> LoginInteraction ()
