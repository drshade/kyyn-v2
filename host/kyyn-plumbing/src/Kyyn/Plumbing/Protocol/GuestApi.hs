{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Plumbing.Protocol.GuestApi (encodeCatalogue, decodeCatalogue) where

import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=), (.:))
import Data.Aeson.Types (Parser, parseEither, withObject)
import Data.ByteString (ByteString)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.GuestApi
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)

encodeCatalogue :: DhallHandling :> es => [ApiModule] -> Eff es (Either [Diagnostic] ByteString)
encodeCatalogue modules = fmap (fmap Text.encodeUtf8) $ encodeValue catalogueShape
  (object ["version" .= ("1" :: String), "modules" .= map moduleValue modules])

decodeCatalogue :: DhallHandling :> es => ByteString -> Eff es (Either [Diagnostic] [ApiModule])
decodeCatalogue bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (bad (show problem))
  Right source -> do
    result <- decodeValue catalogueShape source
    pure $ result >>= either bad Right . parseEither parseCatalogue
  where bad = Left . pure . errorDiagnostic "guest.catalogue"

catalogueShape :: Shape
catalogueShape = Record [("version",Scalar IntegerScalar), ("modules",List (Record
  [("name",text), ("symbols",List (Record
    [("name",text), ("namespace",Union [("Type",Nothing),("Value",Nothing)]), ("definedAs",text), ("checkedSignature",text),
     ("declaration",Optional text), ("documentation",Optional text)]))]))]
  where text = Scalar TextScalar

moduleValue :: ApiModule -> Value
moduleValue (ApiModule name symbols) = object ["name" .= name, "symbols" .= map symbolValue symbols]

symbolValue :: ApiSymbol -> Value
symbolValue (ApiSymbol name namespace origin signature declaration documentation) = object
  [ "name" .= name, "namespace" .= object ["tag" .= namespaceName namespace], "definedAs" .= origin
  , "checkedSignature" .= signature, "declaration" .= optionalText declaration
  , "documentation" .= optionalText documentation ]

optionalText :: Maybe String -> Value
optionalText = maybe (object ["tag" .= ("None" :: String)])
  (\value -> object ["tag" .= ("Some" :: String), "value" .= value])

namespaceName :: Namespace -> String
namespaceName TypeNamespace = "Type"
namespaceName ValueNamespace = "Value"

parseCatalogue :: Value -> Parser [ApiModule]
parseCatalogue = withObject "guest catalogue" $ \fields -> do
  version <- fields .: "version"
  unless (version == ("1" :: String)) (fail "Unsupported guest catalogue format; reinstall Kyyn")
  fields .: "modules" >>= mapM (withObject "module" $ \entry ->
    ApiModule <$> entry .: "name" <*> (entry .: "symbols" >>= mapM parseSymbol))

parseSymbol :: Value -> Parser ApiSymbol
parseSymbol = withObject "symbol" $ \fields -> do
  namespace <- fields .: "namespace" >>= withObject "namespace" (\value -> do
    tag <- value .: "tag"
    case tag :: String of
      "Type" -> pure TypeNamespace
      "Value" -> pure ValueNamespace
      _ -> fail "Unknown guest API namespace")
  ApiSymbol <$> fields .: "name" <*> pure namespace <*> fields .: "definedAs"
    <*> fields .: "checkedSignature" <*> (fields .: "declaration" >>= parseOptionalText)
    <*> (fields .: "documentation" >>= parseOptionalText)

parseOptionalText :: Value -> Parser (Maybe String)
parseOptionalText = withObject "optional text" $ \value -> do
  tag <- value .: "tag"
  case tag :: String of
    "None" -> pure Nothing
    "Some" -> Just <$> value .: "value"
    _ -> fail "Unknown optional text"
