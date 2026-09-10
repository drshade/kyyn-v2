{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.GuestApi (executeGuest) where

import Data.Aeson (Value, object, (.=))
import Effectful (Eff, (:>))
import Kyyn.Domain.GuestApi
import qualified Kyyn.Porcelain.Capability.GuestApi as Api
import Kyyn.Surfaces.Cli (GuestCommand(..))
import Kyyn.Surfaces.Result (Response, success, refusal)

executeGuest :: Api.GuestApi :> es => GuestCommand -> Eff es Response
executeGuest command = case command of
  ListGuestModules -> either refusal (\modules -> success (object ["modules" .= modules]) modules) <$> Api.listModules
  ShowGuestModule selected -> either refusal (\(ApiModule name symbols) -> result name symbols) <$> Api.findModule selected
  ShowGuestSymbol selected -> either refusal (uncurry result) <$> Api.findSymbol selected
  where
    result name symbols = success (object ["module" .= name, "symbols" .= map symbolJson symbols])
      (("module " ++ name) : concatMap symbolText symbols)

symbolJson :: ApiSymbol -> Value
symbolJson (ApiSymbol name namespace origin signature declaration) = object
  [ "name" .= name, "namespace" .= namespaceName namespace, "definedAs" .= origin
  , "checkedSignature" .= signature, "declaration" .= declaration ]

namespaceName :: Namespace -> String
namespaceName TypeNamespace = "type"
namespaceName ValueNamespace = "value"

symbolText :: ApiSymbol -> [String]
symbolText (ApiSymbol name namespace origin signature declaration) =
  [ ""
  , maybe (namespaceName namespace ++ " " ++ name ++ " :: " ++ signature ++ "  [checked]")
      id declaration
  , "  Defined as " ++ origin
  ]
