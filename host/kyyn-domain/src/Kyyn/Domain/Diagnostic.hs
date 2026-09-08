module Kyyn.Domain.Diagnostic (Diagnostic(..)) where

data Diagnostic = Diagnostic
  { code :: String
  , message :: String
  } deriving (Eq, Show)
