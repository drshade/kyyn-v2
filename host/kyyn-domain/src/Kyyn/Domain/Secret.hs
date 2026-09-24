module Kyyn.Domain.Secret (SecretName, secretName, secretNameText, SecretError(..)) where

newtype SecretName = SecretName String deriving (Eq, Ord, Show)

secretName :: String -> Either String SecretName
secretName name
  | not (null name) && all valid name = Right (SecretName name)
  | otherwise = Left "Secret names must contain only ASCII letters, digits, hyphens and underscores, and must not be empty."
  where
    valid c = c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
      || c >= '0' && c <= '9' || c == '-' || c == '_'

secretNameText :: SecretName -> String
secretNameText (SecretName name) = name

data SecretError = SecretNotFound SecretName deriving (Eq, Show)
