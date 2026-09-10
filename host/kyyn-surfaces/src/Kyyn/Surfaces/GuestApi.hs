{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.GuestApi (modulesResult, moduleResult, symbolResult) where

import Data.Aeson (Value, object, (.=))
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.GuestApi
import Kyyn.Surfaces.Result (Response, success, refusal)

modulesResult :: Either [Diagnostic] [String] -> Response
modulesResult = either refusal (\modules -> success (object ["modules" .= modules]) modules)

moduleResult :: Either [Diagnostic] ApiModule -> Response
moduleResult = either refusal (\(ApiModule name symbols) -> result name symbols)

symbolResult :: Either [Diagnostic] (String,[ApiSymbol]) -> Response
symbolResult = either refusal (uncurry result)

result :: String -> [ApiSymbol] -> Response
result name symbols = success (object ["module" .= name, "symbols" .= map symbolJson symbols])
  (("module " ++ name) : concatMap symbolText symbols)

symbolJson :: ApiSymbol -> Value
symbolJson (ApiSymbol name namespace origin signature declaration documentation) = object
  [ "name" .= name, "namespace" .= namespaceName namespace, "definedAs" .= origin
  , "checkedSignature" .= signature, "declaration" .= declaration, "documentation" .= documentation ]

namespaceName :: Namespace -> String
namespaceName TypeNamespace = "type"
namespaceName ValueNamespace = "value"

symbolText :: ApiSymbol -> [String]
symbolText (ApiSymbol name namespace origin signature declaration documentation) =
  [""] ++ maybe [] (map ("  " ++) . lines) documentation
  ++ maybe [namespaceName namespace ++ " " ++ name ++ " :: " ++ signature ++ "  [checked]"] lines declaration
  ++ ["  Defined as " ++ origin]
