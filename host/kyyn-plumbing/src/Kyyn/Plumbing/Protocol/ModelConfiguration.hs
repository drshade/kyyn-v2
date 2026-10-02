module Kyyn.Plumbing.Protocol.ModelConfiguration (configurationShape, decodeConfiguration) where

import Control.Monad (unless)
import Data.Aeson ((.:), withObject)
import Data.Aeson.Types (parseEither)
import Data.Aeson (Value)
import Data.Char (isSpace)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Model (ModelConfiguration(..), ModelProvider(..))
import Kyyn.Domain.Secret (secretName)

configurationShape :: Shape
configurationShape = Record
  [("provider",Union [("OpenAI",Nothing),("Anthropic",Nothing)]),
   ("model",Scalar TextScalar),("credential",Scalar TextScalar)]

decodeConfiguration :: Value -> Either String ModelConfiguration
decodeConfiguration = parseEither $ withObject "model configuration" $ \fields -> do
  provider <- fields .: "provider" >>= withObject "model provider" (\value -> do
    name <- value .: "tag"
    case name :: String of
      "OpenAI" -> pure OpenAI
      "Anthropic" -> pure Anthropic
      _ -> fail "Expected OpenAI or Anthropic")
  model <- fields .: "model"
  unless (any (not . isSpace) model) (fail "Model name must not be blank")
  credential <- fields .: "credential" >>= either fail pure . secretName
  pure (ModelConfiguration provider model credential)
