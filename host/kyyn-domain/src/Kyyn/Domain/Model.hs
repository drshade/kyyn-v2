module Kyyn.Domain.Model (ModelProvider(..), ModelConfiguration(..), ModelFailure(..)) where

import Kyyn.Domain.Secret (SecretName)

data ModelProvider = OpenAI | Anthropic deriving (Eq, Show)

-- | Only a reference to the checkout-local credential belongs in KB configuration.
data ModelConfiguration = ModelConfiguration
  { provider :: ModelProvider, model :: String, credential :: SecretName }
  deriving (Eq, Show)

data ModelFailure = InvalidModelConfiguration | MissingModelSecret SecretName
  | EmptyModelSecret SecretName | ModelAuthenticationRejected | ModelRateLimited
  | ModelUnavailable | ModelRequestRejected | ModelRefused | ModelIncomplete
  | InvalidModelResponse
  deriving (Eq, Show)
